/***************************************************************************
 # Copyright (c) 2015-23, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "stdafx.h"
#include "CustomAccelerationStructure.h"

namespace Falcor
{
    CustomAccelerationStructure::CustomAccelerationStructure(const uint64_t aabbCount, const uint64_t aabbGpuAddress)
    {
        const std::vector count = {aabbCount};
        const std::vector gpuAddress = {aabbGpuAddress};

        createAccelerationStructure(count, gpuAddress);
    }

    CustomAccelerationStructure::CustomAccelerationStructure(const std::vector<uint64_t>& aabbCount, const std::vector<uint64_t>& aabbGpuAddress)
    {
        createAccelerationStructure(aabbCount, aabbGpuAddress);
    }

    CustomAccelerationStructure::~CustomAccelerationStructure()
    {
        clearData();
    }

    void CustomAccelerationStructure::update(RenderContext* pRenderContext)
    {
        const std::vector<uint64_t> count = {0u};
        buildAccelerationStructure(pRenderContext, count, false);
    }

    void CustomAccelerationStructure::update(RenderContext* pRenderContext, const uint64_t aabbCount)
    {
        const std::vector<uint64_t> count = {aabbCount};
        buildAccelerationStructure(pRenderContext, count, true);
    }

    void CustomAccelerationStructure::update(RenderContext* pRenderContext, const std::vector<uint64_t>& aabbCount)
    {
        buildAccelerationStructure(pRenderContext, aabbCount, true);
    }

    void CustomAccelerationStructure::bindTlas(ShaderVar& rootVar, std::string shaderName)
    {
        rootVar[shaderName].setSrv(mTlas.pSrv);
    }

    void CustomAccelerationStructure::createAccelerationStructure(
        const std::vector<uint64_t>& aabbCount,
        const std::vector<uint64_t>& aabbGpuAddress
    )
    {
        clearData();

        assert(aabbCount.size() == aabbGpuAddress.size());

        mNumberBlas = aabbCount.size();

        createBottomLevelAS(aabbCount, aabbGpuAddress);
        createTopLevelAS();
    }

    void CustomAccelerationStructure::clearData()
    {
        // clear all previous data
        for (uint i = 0; i < mBlas.size(); i++)
        {
            mBlas[i].reset();
            //mBlasObjects[i].reset();
        }

        mBlas.clear();
        mBlasData.clear();
        //mBlasObjects.clear();
        mInstanceDesc.clear();
        mTlasScratch.reset();
        mTlas.pInstanceDescs.reset();
        mTlas.pTlas.reset();
        mTlas.pSrv.reset();
    }

    void CustomAccelerationStructure::createBottomLevelAS(const std::vector<uint64_t> aabbCount, const std::vector<uint64_t> aabbGpuAddress)
    {
        // Create Number of desired blas and reset max size
        mBlasData.resize(mNumberBlas);
        mBlas.resize(mNumberBlas);
        //mBlasObjects.resize(mNumberBlas);
        mBlasScratchMaxSize = 0;

        assert(aabbCount.size() >= mNumberBlas);
        assert(aabbGpuAddress.size() >= mNumberBlas);

        // Prebuild
        for (size_t i = 0; i < mNumberBlas; i++)
        {
            auto& blas = mBlasData[i];

            // Create geometry description
            auto& desc = blas.geomDescs;
            desc.Type = D3D12_RAYTRACING_GEOMETRY_TYPE_PROCEDURAL_PRIMITIVE_AABBS;
            desc.Flags = D3D12_RAYTRACING_GEOMETRY_FLAG_NO_DUPLICATE_ANYHIT_INVOCATION; //< Important! So that photons are not collected multiple times

            desc.AABBs.AABBCount = aabbCount[i];
            desc.AABBs.AABBs.StartAddress = aabbGpuAddress[i];
            desc.AABBs.AABBs.StrideInBytes = sizeof(D3D12_RAYTRACING_AABB);

            // Create input for blas
            auto& inputs = blas.buildInputs;
            inputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
            inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
            inputs.NumDescs = 1;
            inputs.pGeometryDescs = &blas.geomDescs;

            //Build option flags
            // TODO Check for performance if neither is activated
            inputs.Flags = mFastBuild ? D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD : D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
            if (mUpdate)
                inputs.Flags |= D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_ALLOW_UPDATE;

            // Get prebuild Info
            GET_COM_INTERFACE(gpDevice->getApiHandle(), ID3D12Device5, pDevice5);
            pDevice5->GetRaytracingAccelerationStructurePrebuildInfo(&blas.buildInputs, &blas.prebuildInfo);

            // Figure out the padded allocation sizes to have proper alignment.
            assert(blas.prebuildInfo.resultDataMaxSize > 0);
            blas.blasByteSize = align_to((uint64_t)D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT, blas.prebuildInfo.ResultDataMaxSizeInBytes);

            uint64_t scratchByteSize = std::max(blas.prebuildInfo.ScratchDataSizeInBytes, blas.prebuildInfo.UpdateScratchDataSizeInBytes);
            blas.scratchByteSize = align_to((uint64_t)D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT, scratchByteSize);

            mBlasScratchMaxSize = std::max(blas.scratchByteSize, mBlasScratchMaxSize);
        }

        // Create the scratch and blas buffers
        mBlasScratch = Buffer::create(mBlasScratchMaxSize, Buffer::BindFlags::UnorderedAccess);
        mBlasScratch->setName("CustomAS::BlasScratch");

        for (uint i = 0; i < mNumberBlas; i++)
        {
            mBlas[i] = Buffer::create(mBlasData[i].blasByteSize, Buffer::BindFlags::AccelerationStructure);
            mBlas[i]->setName("CustomAS::BlasBuffer" + std::to_string(i));

            // Create API object
            /*
            RtAccelerationStructure::Desc blasDesc = {};
            blasDesc.setBuffer(mBlas[i], 0u, mBlasData[i].blasByteSize);
            blasDesc.setKind(RtAccelerationStructureKind::BottomLevel);
            mBlasObjects[i] = RtAccelerationStructure::create(mpDevice, blasDesc);
            */
        }
    }

    void CustomAccelerationStructure::createTopLevelAS()
    {
        mInstanceDesc.clear(); // clear to be sure that it is empty

        // fill the instance description if empty
        for (int i = 0; i < mNumberBlas; i++)
        {
            D3D12_RAYTRACING_INSTANCE_DESC  desc = {};
            desc.AccelerationStructure = mBlas[i]->getGpuAddress();
            desc.Flags = D3D12_RAYTRACING_INSTANCE_FLAG_NONE;
            desc.InstanceID = i;
            desc.InstanceMask = mNumberBlas < 8 ? 1 << i : 0xFF; // For up to 8 they are instanced seperatly
            desc.InstanceContributionToHitGroupIndex = 0;

            // Create a identity matrix for the transform and copy it to the instance desc
            glm::mat4 identityMat = glm::identity<glm::mat4>();
            std::memcpy(desc.Transform, &identityMat, sizeof(desc.Transform)); // Copy transform
            mInstanceDesc.push_back(desc);
        }

        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS  inputs = {};
        inputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
        inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
        inputs.NumDescs = (uint32_t)mNumberBlas;
        inputs.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD; // TODO Check performance for Fast Trace or Fast Update

        // Prebuild
        GET_COM_INTERFACE(gpDevice->getApiHandle(), ID3D12Device5, pDevice5);
        pDevice5->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &mTlasPrebuildInfo);
        mTlasScratch = Buffer::create(mTlasPrebuildInfo.ScratchDataSizeInBytes, Buffer::BindFlags::UnorderedAccess, Buffer::CpuAccess::None);
        mTlasScratch->setName("CustomAS::TLAS_Scratch");

        // Create buffers for the TLAS
        mTlas.pTlas =
            Buffer::create(mTlasPrebuildInfo.ResultDataMaxSizeInBytes, Buffer::BindFlags::AccelerationStructure, Buffer::CpuAccess::None);
        mTlas.pTlas->setName("CustomAS::TLAS");
        mTlas.pInstanceDescs = Buffer::create((uint32_t)mInstanceDesc.size() * sizeof(D3D12_RAYTRACING_INSTANCE_DESC), Buffer::BindFlags::None, Buffer::CpuAccess::Write,
            mInstanceDesc.data()
        );
        mTlas.pInstanceDescs->setName("CustomAS::TLAS_Instance_Description");

        //Acceleration Structure Buffer view for access in shader
        mTlas.pSrv = ShaderResourceView::createViewForAccelerationStructure(mTlas.pTlas);

        // Create API object
        /*
        RtAccelerationStructure::Desc tlasDesc = {};
        tlasDesc.setBuffer(mTlas.pTlas, 0u, mTlasPrebuildInfo.resultDataMaxSize);
        tlasDesc.setKind(RtAccelerationStructureKind::TopLevel);
        mTlas.pTlasObject = RtAccelerationStructure::create(mpDevice, tlasDesc);
        */
    }

    void CustomAccelerationStructure::buildAccelerationStructure(
        RenderContext* pRenderContext,
        const std::vector<uint64_t>& aabbCount,
        bool updateAABBCount
    )
    {
        // Check if buffers exists
        assert(mBlas[0]);
        assert(mTlas.pTlas);

        assert(aabbCount.size() >= mNumberBlas);

        buildBottomLevelAS(pRenderContext, aabbCount, updateAABBCount);
        buildTopLevelAS(pRenderContext);
    }

    void CustomAccelerationStructure::buildBottomLevelAS(
        RenderContext* pRenderContext,
        const std::vector<uint64_t>& aabbCount,
        bool updateAABBCount
    )
    {
        PROFILE("buildCustomBlas");

        for (size_t i = 0; i < mNumberBlas; i++)
        {
            auto& blas = mBlasData[i];

            // barriers for the scratch and blas buffer
            pRenderContext->uavBarrier(mBlasScratch.get());
            pRenderContext->uavBarrier(mBlas[i].get());

            if (updateAABBCount)
                blas.geomDescs.AABBs.AABBCount = aabbCount[i];

            // Fill the build desc struct
            D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC asDesc = {};
            asDesc.Inputs = blas.buildInputs;
            asDesc.ScratchAccelerationStructureData = mBlasScratch->getGpuAddress();
            asDesc.DestAccelerationStructureData = mBlas[i]->getGpuAddress();

            // Build the acceleration structure
            GET_COM_INTERFACE(pRenderContext->getLowLevelData()->getCommandList(), ID3D12GraphicsCommandList4, pList4);
            pList4->BuildRaytracingAccelerationStructure(&asDesc, 0, nullptr);

            // Barrier for the blas
            pRenderContext->uavBarrier(mBlas[i].get());
        }
    }

    void CustomAccelerationStructure::buildTopLevelAS(RenderContext* pRenderContext)
    {
        PROFILE("buildCustomTlas");

        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS inputs = {};
        inputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
        inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
        inputs.NumDescs = (uint32_t)mInstanceDesc.size();
        // Update Flag could be set for TLAS. This made no real time difference in our test so it is left out. Updating could reduce the memory
        // of the TLAS scratch buffer a bit
        inputs.Flags = mFastBuild ? D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_BUILD : D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE;
        if (mUpdate)
            inputs.Flags |= D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_ALLOW_UPDATE;

        D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC asDesc = {};
        asDesc.Inputs = inputs;
        asDesc.Inputs.InstanceDescs = mTlas.pInstanceDescs->getGpuAddress();
        asDesc.ScratchAccelerationStructureData = mTlasScratch->getGpuAddress();
        asDesc.DestAccelerationStructureData = mTlas.pTlas->getGpuAddress();

        // Create TLAS
        if (mTlas.pInstanceDescs)
        {
            pRenderContext->resourceBarrier(mTlas.pInstanceDescs.get(), Resource::State::NonPixelShader);
        }

        GET_COM_INTERFACE(pRenderContext->getLowLevelData()->getCommandList(), ID3D12GraphicsCommandList4, pList4);
        pList4->BuildRaytracingAccelerationStructure(&asDesc, 0, nullptr);    

        // Barrier for the blas
        pRenderContext->uavBarrier(mTlas.pTlas.get());
    }

}
