//
//  ViewController.swift
//  SegmentationAndOcclusion
//
//  Created by Dennis Ippel on 07/10/2020.
//

import UIKit
import Vision
import ARKit

var width = 1.0
var height = 1.0

class ViewController: UIViewController, ARSCNViewDelegate {

    @IBOutlet weak var sceneView: ARSCNView!
    
    private var screenSize: CGSize!
    private var textureCache: CVMetalTextureCache?
    
    // Deeplab labels
    private let labels = ["background", "aeroplane", "bicycle", "bird", "board", "bottle", "bus", "car", "cat", "chair", "cow", "diningTable", "dog", "horse", "motorbike", "person", "pottedPlant", "sheep", "sofa", "train", "tvOrMonitor", "individual", "someone"]
    private let targetObjectLabel = ["sofa", "car", "person"]
    private var targetObjectLabelindex: [UInt] {
        let index0 = UInt(labels.firstIndex(of: targetObjectLabel[0]) ?? 0)
        let index1 = UInt(labels.firstIndex(of: targetObjectLabel[1]) ?? 0)
        let index2 = UInt(labels.firstIndex(of: targetObjectLabel[2]) ?? 0)
        let indices = [index0, index1, index2]
        return indices

    }
    
    private weak var quadNode: SegmentationMaskNode?
    private weak var highlighterNode: SCNNode?
    
    private weak var quadNode2: SegmentationMaskNode?
    private weak var highlighterNode2: SCNNode?
    
    override var shouldAutorotate: Bool { return false }
    
    lazy var segmentationRequest: VNCoreMLRequest = {
        do {
            let model = try VNCoreMLModel(for: DeepLabV3Int8Image(configuration: MLModelConfiguration()).model)
            let request = VNCoreMLRequest(model: model) { [weak self] request, error in
                self?.processSegmentations(for: request, error: error)
            }
            request.imageCropAndScaleOption = .scaleFill
            return request
        } catch {
            fatalError("Failed to load Vision ML model.")
        }
    }()
    
    lazy var objectDetectionRequest: VNCoreMLRequest = {
        do {
            let model = try VNCoreMLModel(for: YOLOv3Int8LUT(configuration: MLModelConfiguration()).model)
            let request = VNCoreMLRequest(model: model) { [weak self] request, error in
                self?.processObjectDetections(for: request, error: error)
            }
            request.imageCropAndScaleOption = .scaleFill
            return request
        } catch {
            fatalError("Failed to load Vision ML model.")
        }
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        sceneView.delegate = self
        
        screenSize = UIScreen.main.bounds.size
        
        let quadNode = SegmentationMaskNode(sceneView: sceneView)
        quadNode.classificationLabelIndex = targetObjectLabelindex
        sceneView.scene.rootNode.addChildNode(quadNode)
        
        self.quadNode = quadNode
        
        let highlighterNode = HighlighterNode()
        highlighterNode.isHidden = true
        sceneView.scene.rootNode.addChildNode(highlighterNode)
        highlighterNode.name = "highlighterNode"
        self.highlighterNode = highlighterNode
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resetTracking()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }
    
    private func resetTracking() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = []
        configuration.environmentTexturing = .automatic
        sceneView.session.run(configuration, options: [.removeExistingAnchors, .resetTracking])
    }
    
    private func processSegmentations(for request: VNRequest, error: Error?) {
        guard error == nil else {
            print("Segmentation error: \(error!.localizedDescription)")
            return
        }
        
        guard let observation = request.results?.first as? VNPixelBufferObservation else { return }
        
//        print(observation)
        // The kCVPixelBufferMetalCompatibilityKey needs to be set if we want
        // to use the texture in a Metal shader.
        let pixelBuffer = observation.pixelBuffer.copyToMetalCompatible()!
        
        if textureCache == nil && CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, MTLCreateSystemDefaultDevice()!, nil, &textureCache) != kCVReturnSuccess {
            assertionFailure()
            return
        }

        var segmentationTexture: CVMetalTexture?

        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               textureCache.unsafelyUnwrapped,
                                                               pixelBuffer,
                                                               nil,
                                                               .r8Uint,
                                                               CVPixelBufferGetWidth(pixelBuffer),
                                                               CVPixelBufferGetHeight(pixelBuffer),
                                                               0,
                                                               &segmentationTexture)

        guard result == kCVReturnSuccess,
              let image = segmentationTexture,
              let texture = CVMetalTextureGetTexture(image)
        else { return }

        quadNode?.segmentationTexture = texture
    }
    
    private func processObjectDetections(for request: VNRequest, error: Error?) {
        guard error == nil else {
            print("Object detection error: \(error!.localizedDescription)")
            return
        }
        
        guard var objectObservations = request.results as? [VNRecognizedObjectObservation] else { return }
        
        objectObservations.sort {
            return $0.labels.firstIndex(where: { $0.identifier == targetObjectLabel[0] }) ?? -1 < $1.labels.firstIndex(where: { $0.identifier == targetObjectLabel[0] }) ?? -1 ||
            $0.labels.firstIndex(where: { $0.identifier == targetObjectLabel[1] }) ?? -1 < $1.labels.firstIndex(where: { $0.identifier == targetObjectLabel[1] }) ?? -1 ||
            $0.labels.firstIndex(where: { $0.identifier == targetObjectLabel[2] }) ?? -1 < $1.labels.firstIndex(where: { $0.identifier == targetObjectLabel[2] }) ?? -1
        }
        
        guard let bestObservation = objectObservations.first,
              let index = bestObservation.labels.firstIndex(where: { $0.identifier == targetObjectLabel[0] || $0.identifier == targetObjectLabel[1] || $0.identifier == targetObjectLabel[2] }),
              index < 3
        else { return }
        
        // Enlarge the region of interest slightly to get better results
        let enlargedRegionOfInterest = bestObservation.boundingBox.insetByNormalized(d: -0.02)
        width = bestObservation.boundingBox.width
        height = bestObservation.boundingBox.height
        
        HighlighterNode().updateNode(w: width, h: height)
        
        segmentationRequest.regionOfInterest = enlargedRegionOfInterest
        quadNode?.regionOfInterest = enlargedRegionOfInterest
        placeHighlighterNode(atCenterOfBoundingBox: enlargedRegionOfInterest)
    }
    
    private func placeHighlighterNode(atCenterOfBoundingBox boundingBox: CGRect) {
        guard let displayTransform = sceneView.session.currentFrame?.displayTransform(for: .landscapeLeft, viewportSize: screenSize) else { return }
        
        let viewBoundingBox = viewSpaceBoundingBox(fromNormalizedImageBoundingBox: boundingBox,
                                                   usingDisplayTransform: displayTransform)
        
        
        let midPoint = CGPoint(x: viewBoundingBox.midX,
                               y: viewBoundingBox.midY)
        
        // Get the feature point that is closed to our detected rectangle's center
        let results = sceneView.hitTest(midPoint, types: .featurePoint)
        
        guard let result = results.first else { return }
        
        let translation =  result.worldTransform.columns.3
        highlighterNode?.simdWorldPosition = simd_float3(translation.x, translation.y, translation.z)
        highlighterNode?.isHidden = false
        
        guard let camera = sceneView.pointOfView?.camera else { return }
        
        // Calculate the z buffer value so we can use it in the fragment shader.
        // For the sake of occulsion, we need to write this value into the depth buffer.
        // This will happen in the fragment shader.
        quadNode?.depthBufferZ = calculateFragmentDepth(usingCamera: camera,
                                                        distanceToTarget: Double(result.distance),
                                                        usesReverseZ: sceneView.usesReverseZ)
    }
    
    private func calculateFragmentDepth(usingCamera camera: SCNCamera, distanceToTarget: Double, usesReverseZ: Bool) -> Float {
        // SceneKit uses a reverse z buffer since iOS 13. In case it uses a reverse buffer.
        // We'll need to swap the near and far planes.
        let zFar = usesReverseZ ? camera.zNear : camera.zFar
        let zNear = usesReverseZ ? camera.zFar : camera.zNear
        let range = 2.0 * zNear * zFar
        // The depth value in in normalized device coordinates [-1, 1].
        let fragmentDepth = (zFar + zNear - range / distanceToTarget) / (zFar - zNear)
        // Convert to normalized coordinates [0, 1].
        return Float((fragmentDepth + 1.0) / 2.0)
    }
    
    private func viewSpaceBoundingBox(fromNormalizedImageBoundingBox imageBoundingBox: CGRect,
                                      usingDisplayTransform displayTransorm: CGAffineTransform) -> CGRect {
        // Transform into normalized view coordinates
        let viewNormalizedBoundingBox = imageBoundingBox.applying(displayTransorm)
        // The affine transform for view coordinates
        let t = CGAffineTransform(scaleX: screenSize.width, y: screenSize.height)
        // Scale up to view coordinates
        return viewNormalizedBoundingBox.applying(t)
    }
    
    func renderer(_ renderer: SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard let capturedImage = sceneView.session.currentFrame?.capturedImage else { return }
        
        // We'll have to take into account the different aspect ratios
        let capturedImageAspectRatio = Float(CVPixelBufferGetWidth(capturedImage)) / Float(CVPixelBufferGetHeight(capturedImage))
        let screenAspectRatio = Float(screenSize.height / screenSize.width)
        quadNode?.aspectRatioAdjustment = screenAspectRatio / capturedImageAspectRatio
        
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: capturedImage,
                                                        orientation: .leftMirrored,
                                                        options: [:])
        do {
            try imageRequestHandler.perform([objectDetectionRequest, segmentationRequest])
        } catch {
            print("Failed to perform image request. \(error)")
        }
    }
}
