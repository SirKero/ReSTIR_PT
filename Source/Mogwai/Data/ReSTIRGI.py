from falcor import *

def render_graph_ReSTIR_GI():
    g = RenderGraph('ReSTIR_GI')
    loadRenderPassLibrary('AccumulatePass.dll')
    loadRenderPassLibrary('ReSTIR_GI.dll')
    loadRenderPassLibrary('ScreenSpaceReSTIRPass.dll')
    loadRenderPassLibrary('GBuffer.dll')
    loadRenderPassLibrary('ToneMapper.dll')
    VBufferRT = createPass("VBufferRT", {'samplePattern': SamplePattern.Center, 'sampleCount': 1, 'texLOD': TexLODMode.Mip0, 'useAlphaTest': True})
    g.addPass(VBufferRT, 'VBufferRT')
    AccumulatePass = createPass('AccumulatePass', {'enabled': True, 'outputSize': IOSize.Default, 'autoReset': True, 'precisionMode': AccumulatePrecision.Double, 'subFrameCount': 0, 'maxAccumulatedFrames': 0})
    g.addPass(AccumulatePass, 'AccumulatePass')
    ReSTIR_GI = createPass('ReSTIR_GI')
    g.addPass(ReSTIR_GI, 'ReSTIR_GI')
    ToneMapper = createPass('ToneMapper', {'outputSize': IOSize.Default, 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': ToneMapOp.Aces, 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': ExposureMode.AperturePriority, 'irayExposure': False})
    g.addPass(ToneMapper, 'ToneMapper')
    ScreenSpaceReSTIRPass = createPass("ScreenSpaceReSTIRPass")    
    g.addPass(ScreenSpaceReSTIRPass, "ScreenSpaceReSTIRPass")
    
    g.addEdge('VBufferRT.vbuffer', 'ReSTIR_GI.vbuffer')
    g.addEdge('VBufferRT.mvec', 'ReSTIR_GI.mvec')
    
    g.addEdge("VBufferRT.vbuffer", "ScreenSpaceReSTIRPass.vbuffer")   
    g.addEdge("VBufferRT.mvec", "ScreenSpaceReSTIRPass.motionVectors")    
    g.addEdge("ScreenSpaceReSTIRPass.color" , "ReSTIR_GI.colorReSTIR")
    
    g.addEdge('ReSTIR_GI.color', 'AccumulatePass.input')
    g.addEdge('AccumulatePass.output', 'ToneMapper.src')
    
    g.markOutput('ToneMapper.dst')
    g.markOutput('AccumulatePass.output')
    
    return g

ReSTIR_GI = render_graph_ReSTIR_GI()
try: m.addGraph(ReSTIR_GI)
except NameError: None
