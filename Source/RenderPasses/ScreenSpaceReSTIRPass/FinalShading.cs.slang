/***************************************************************************
 # Copyright (c) 2015-21, NVIDIA CORPORATION. All rights reserved.
 #
 # NVIDIA CORPORATION and its licensors retain all intellectual property
 # and proprietary rights in and to this software, related documentation
 # and any modifications thereto.  Any use, reproduction, disclosure or
 # distribution of this software and related documentation without an express
 # license agreement from NVIDIA CORPORATION is strictly prohibited.
 **************************************************************************/
import LoadShadingData;

import Utils.Math.PackedFormats;
import Utils.Math.FormatConversion;

import Scene.RaytracingInline;
import Scene.Raytracing;
import Scene.HitInfo;
import Utils.Math.MathHelpers;
import Rendering.Materials.StandardMaterial;
import Rendering.Materials.MaterialShading;
import Rendering.Materials.Microfacet;
import Experimental.ScreenSpaceReSTIR.ScreenSpaceReSTIR;
import Utils.Color.ColorHelpers;



RWTexture2D<float4> gColor;
RWTexture2D<float4> gEmission;
RWTexture2D<float4> gDiffuseIllumination;
RWTexture2D<float4> gDiffuseReflectance;
RWTexture2D<float4> gSpecularIllumination;
RWTexture2D<float4> gSpecularReflectance;
RWTexture2D<float4> gDebug;

#define is_valid(name) (is_valid_##name != 0)

/** Perform shading with final samples from ReSTIR.
*/
struct FinalShading
{
    // Static configuration.
    //static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
    Texture2D<float4> gViewTexture;
    Texture2D<float4> gThpTexture;
    Texture2D<PackedHitInfo> gVBuffer;
    

    ScreenSpaceReSTIR screenSpaceReSTIR;
    StandardMaterial standardMaterial;

    uint2 frameDim;

    uint numReSTIRInstances;
    uint ReSTIRInstanceID;
    
    //Load in shading data from hit and direction
    ShadingData loadShadingDataView(const HitInfo hit, const float3 rayDir)
    {
        const TriangleHit triangleHit = hit.getTriangleHit();
        VertexData v = gScene.getVertexData(triangleHit);
        uint materialID = gScene.getMaterialID(triangleHit.instanceID);
        ShadingData sd = prepareShadingData(v, materialID, gScene.materials[materialID], gScene.materialResources[materialID], -rayDir, 0.f);
        adjustShadingNormal(sd, v);
        
        return sd;
    }
    
    void execute(uint2 pixel)
    {
        if (any(pixel >= frameDim)) return;

        float3 color = {};
        float3 emission = {};
        float3 diffuseReflectance = {};
        float3 diffuseIllumination = {};
        float3 specularReflectance = {};
        float3 specularIllumination = {};
        float hitT = 10000.f; // TODO: Remove magic number also used in SpatioTemporalResampling pass.

        bool valid = false;
        ShadingData sd;
        #if VIEW_VALID
        PackedHitInfo packedHitInfo = gVBuffer[pixel];
        HitInfo hitInfo = HitInfo(packedHitInfo);
        float3 viewDir = -gViewTexture[pixel].xyz;
        valid = hitInfo.isValid();
        if(valid)
            sd = loadShadingDataView(hitInfo, viewDir);
        #else
        valid = loadShadingData(pixel, frameDim, gScene.camera, gVBuffer, sd);
        PackedHitInfo packedHitInfo = gVBuffer[pixel];
        HitInfo hitInfo = HitInfo(packedHitInfo);
        valid = hitInfo.isValid();
        #endif
        if (valid)
        {
            // Get final sample from ReSTIR.

            float3 dir;
            float distance;
            float3 Li;
            bool valid = screenSpaceReSTIR.getFinalSample(pixel, dir, distance, Li);

            // Evaluate diffuse and specular lobes.
            float3 diffuse = {};
            float3 specular = {};
            if (valid)
            {
                sd.setActiveLobes((uint)LobeType::DiffuseReflection);
                diffuse = standardMaterial.eval(sd, dir) * Li;

                sd.setActiveLobes((uint)LobeType::SpecularReflection);
                specular = standardMaterial.eval(sd, dir) * Li;

                hitT = distance;
            }

            emission = sd.emissive;

            color += diffuse + specular + emission;
            
            #if THP_VALID
            color *= gThpTexture[pixel].xyz;
            #endif
           
            // Demodulate diffuse reflectance (albedo) from diffuse color.
            diffuseReflectance += sd.diffuse;
            float3 diffuseFactor = diffuseReflectance <= 0.f ? 0.f : 1.f / diffuseReflectance;
            diffuseIllumination += diffuse * diffuseFactor;

            // Demodulate preintegrated specular reflectance from specular color.
            specularReflectance += approxSpecularIntegralGGX(sd.specular, sd.linearRoughness * sd.linearRoughness, sd.NdotV);
            float3 specularFactor = specularReflectance <= 0.f ? 0.f : 1.f / specularReflectance;
            specularIllumination += specular * specularFactor;
        }
        else
        {
            //if (kUseEnvBackground)
            //{
            //    float3 dir = gScene.camera.computeRayPinhole(pixel, frameDim).dir;
            //    emission = gScene.envMap.eval(dir);
            //    color = emission;
            //}
        }

        // Write active outputs.

        if (ReSTIRInstanceID == 0)
        {
            if (is_valid(gColor)) gColor[pixel] = float4(color, 1.f) / numReSTIRInstances;
            if (is_valid(gEmission)) gEmission[pixel] = float4(emission, 1.f) / numReSTIRInstances;
            if (is_valid(gDiffuseReflectance)) gDiffuseReflectance[pixel] = float4(diffuseReflectance, 1.f) / numReSTIRInstances;
            if (is_valid(gDiffuseIllumination)) gDiffuseIllumination[pixel] = float4(diffuseIllumination, hitT) / numReSTIRInstances;
            if (is_valid(gSpecularReflectance)) gSpecularReflectance[pixel] = float4(specularReflectance, 1.f) / numReSTIRInstances;
            if (is_valid(gSpecularIllumination)) gSpecularIllumination[pixel] = float4(specularIllumination, hitT) / numReSTIRInstances;
        }
        else
        {
            if (is_valid(gColor)) gColor[pixel] += float4(color, 1.f) / numReSTIRInstances;
            if (is_valid(gEmission)) gEmission[pixel] += float4(emission, 1.f) / numReSTIRInstances;
            if (is_valid(gDiffuseReflectance)) gDiffuseReflectance[pixel] += float4(diffuseReflectance, 1.f) / numReSTIRInstances;
            if (is_valid(gDiffuseIllumination)) gDiffuseIllumination[pixel] += float4(diffuseIllumination, hitT) / numReSTIRInstances;
            if (is_valid(gSpecularReflectance)) gSpecularReflectance[pixel] += float4(specularReflectance, 1.f) / numReSTIRInstances;
            if (is_valid(gSpecularIllumination)) gSpecularIllumination[pixel] += float4(specularIllumination, hitT) / numReSTIRInstances;
        }
    }
};

cbuffer CB
{
    FinalShading gFinalShading;
};

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gFinalShading.execute(dispatchThreadId.xy);
}
