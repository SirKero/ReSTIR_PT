from falcor import *

def render_graph_ReSTIR_GI():
    g = RenderGraph('ReSTIR_GI')
    loadRenderPassLibrary('AccumulatePass.dll')
    loadRenderPassLibrary('ReSTIR_GI.dll')
    loadRenderPassLibrary('ScreenSpaceReSTIRPass.dll')
    loadRenderPassLibrary('GBuffer.dll')
    loadRenderPassLibrary('ToneMapper.dll')
    loadRenderPassLibrary('Utils.dll')
    loadRenderPassLibrary('VideoRecorder.dll')
    
    VBufferRT = createPass("VBufferRT", {'samplePattern': SamplePattern.Center, 'sampleCount': 1, 'texLOD': TexLODMode.Mip0, 'useAlphaTest': True})
    g.addPass(VBufferRT, 'VBufferRT')
    AccumulatePass = createPass('AccumulatePass', {'enabled': True, 'outputSize': IOSize.Default, 'autoReset': True, 'precisionMode': AccumulatePrecision.Double, 'subFrameCount': 0, 'maxAccumulatedFrames': 0})
    g.addPass(AccumulatePass, 'AccumulatePass')
    ReSTIR_GI = createPass('ReSTIR_GI')
    g.addPass(ReSTIR_GI, 'ReSTIR_GI')
    ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0, 'operator': ToneMapOp.Linear})
    g.addPass(ToneMapper, 'ToneMapper')
    ScreenSpaceReSTIRPass = createPass("ScreenSpaceReSTIRPass")    
    g.addPass(ScreenSpaceReSTIRPass, "ScreenSpaceReSTIRPass")
    Composite = createPass('Composite', {'mode': CompositeMode.Add, 'scaleA': 1.0, 'scaleB': 1.0, 'outputFormat': ResourceFormat.RGBA32Float})
    g.addPass(Composite, 'Composite')
    
    VideoRecorder = createPass('VideoRecorder')
    g.addPass(VideoRecorder, 'VideoRecorder')
    
    g.addEdge('VideoRecorder', 'VBufferRT')
    g.addEdge('VBufferRT.vbuffer', 'ReSTIR_GI.vbuffer')
    g.addEdge('VBufferRT.mvec', 'ReSTIR_GI.mvec')
        
    g.addEdge("ReSTIR_GI.vbufferOut", "ScreenSpaceReSTIRPass.vbuffer")   
    g.addEdge("VBufferRT.mvec", "ScreenSpaceReSTIRPass.motionVectors")
    g.addEdge("ReSTIR_GI.thp", "ScreenSpaceReSTIRPass.throughput")    
    g.addEdge("ReSTIR_GI.view", "ScreenSpaceReSTIRPass.view")  
    g.addEdge("ReSTIR_GI.prevView", "ScreenSpaceReSTIRPass.prevView")        
    
    g.addEdge('ReSTIR_GI.color', 'Composite.A')
    g.addEdge('ScreenSpaceReSTIRPass.color', 'Composite.B')
    g.addEdge('Composite.out', 'AccumulatePass.input')
    
    g.addEdge('AccumulatePass.output', 'ToneMapper.src')
    
    g.markOutput('ToneMapper.dst')
    g.markOutput('AccumulatePass.output')
    
    return g

ReSTIR_GI = render_graph_ReSTIR_GI()
try: m.addGraph(ReSTIR_GI)
except NameError: None

