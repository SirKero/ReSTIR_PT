from falcor import *

def render_graph_ReSTIR_FG():
    g = RenderGraph('ReSTIR_FG')
    loadRenderPassLibrary('AccumulatePass.dll')
    loadRenderPassLibrary('ReSTIRFG.dll')
    loadRenderPassLibrary('ScreenSpaceReSTIRPass.dll')
    loadRenderPassLibrary('GBuffer.dll')
    loadRenderPassLibrary('ToneMapper.dll')
    loadRenderPassLibrary('Utils.dll')
    loadRenderPassLibrary('VideoRecorder.dll')
    
    VBufferRT = createPass("VBufferRT", {'samplePattern': SamplePattern.Center, 'sampleCount': 1, 'texLOD': TexLODMode.Mip0, 'useAlphaTest': True})
    g.addPass(VBufferRT, 'VBufferRT')
    AccumulatePass = createPass('AccumulatePass', {'enabled': True, 'outputSize': IOSize.Default, 'autoReset': True, 'precisionMode': AccumulatePrecision.Double, 'subFrameCount': 0, 'maxAccumulatedFrames': 0})
    g.addPass(AccumulatePass, 'AccumulatePass')
    ReSTIRFG = createPass('ReSTIRFG')
    g.addPass(ReSTIRFG, 'ReSTIRFG')
    ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0, 'operator': ToneMapOp.Linear})
    g.addPass(ToneMapper, 'ToneMapper')
    ScreenSpaceReSTIRPass = createPass("ScreenSpaceReSTIRPass")    
    g.addPass(ScreenSpaceReSTIRPass, "ScreenSpaceReSTIRPass")
    Composite = createPass('Composite', {'mode': CompositeMode.Add, 'scaleA': 1.0, 'scaleB': 1.0, 'outputFormat': ResourceFormat.RGBA32Float})
    g.addPass(Composite, 'Composite')
    
    VideoRecorder = createPass('VideoRecorder')
    g.addPass(VideoRecorder, 'VideoRecorder')
    
    g.addEdge('VideoRecorder', 'VBufferRT')
    g.addEdge('VBufferRT.vbuffer', 'ReSTIRFG.vbuffer')
    g.addEdge('VBufferRT.mvec', 'ReSTIRFG.mvec')
        
    g.addEdge("ReSTIRFG.vbufferOut", "ScreenSpaceReSTIRPass.vbuffer")   
    g.addEdge("VBufferRT.mvec", "ScreenSpaceReSTIRPass.motionVectors")
    g.addEdge("ReSTIRFG.thp", "ScreenSpaceReSTIRPass.throughput")    
    g.addEdge("ReSTIRFG.view", "ScreenSpaceReSTIRPass.view")  
    g.addEdge("ReSTIRFG.prevView", "ScreenSpaceReSTIRPass.prevView")        
    
    g.addEdge('ReSTIRFG.color', 'Composite.A')
    g.addEdge('ScreenSpaceReSTIRPass.color', 'Composite.B')
    g.addEdge('Composite.out', 'AccumulatePass.input')
    
    g.addEdge('AccumulatePass.output', 'ToneMapper.src')
    
    g.markOutput('ToneMapper.dst')
    g.markOutput('AccumulatePass.output')
    
    return g

ReSTIR_FG = render_graph_ReSTIR_FG()
try: m.addGraph(ReSTIR_FG)
except NameError: None
