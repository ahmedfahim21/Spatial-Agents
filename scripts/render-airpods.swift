#!/usr/bin/env swift
// Renders a USDZ model into a transparent frame sequence for the landing page, so the site
// can turn it with the pointer without shipping a 3D engine.
//
//   swift scripts/render-airpods.swift <model.usdz> <output-dir> [frames] [size]
import AppKit
import SceneKit

let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("usage: render-airpods.swift <model.usdz> <output-dir> [frames] [size]") }
let frames = args.count > 3 ? Int(args[3])! : 25
let size = args.count > 4 ? Int(args[4])! : 900
let sweep: CGFloat = 50 // degrees either side of straight on

let scene = try SCNScene(url: URL(fileURLWithPath: args[1]), options: [.checkConsistency: false])
let model = SCNNode()
for child in scene.rootNode.childNodes { model.addChildNode(child) }
scene.rootNode.addChildNode(model)

let (lo, hi) = model.boundingBox
let center = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
let extent = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
print("bounds", lo, hi, "extent", extent)
model.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)

let camera = SCNCamera()
camera.usesOrthographicProjection = false
camera.fieldOfView = 22
camera.zNear = Double(extent) * 0.01
camera.zFar = Double(extent) * 40
let eye = SCNNode()
eye.camera = camera
eye.position = SCNVector3(0, 0, extent * 3.0)
scene.rootNode.addChildNode(eye)

func light(_ type: SCNLight.LightType, _ intensity: CGFloat, at p: SCNVector3? = nil) {
    let l = SCNLight()
    l.type = type
    l.intensity = intensity
    let n = SCNNode()
    n.light = l
    if let p {
        n.position = p
        n.look(at: SCNVector3(0, 0, 0))
    }
    scene.rootNode.addChildNode(n)
}
light(.ambient, 150)
light(.directional, 520, at: SCNVector3(-extent, extent * 1.8, extent * 1.6))
light(.directional, 130, at: SCNVector3(extent * 1.8, extent * 0.2, extent))

// A soft studio: bright overhead falling to grey at the floor, for reflections on the shell.
let studio = NSImage(size: NSSize(width: 256, height: 128), flipped: false) { rect in
    NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.5, alpha: 1), NSColor(white: 0.95, alpha: 1)])!
        .draw(in: rect, angle: 90)
    return true
}
scene.lightingEnvironment.contents = studio
scene.lightingEnvironment.intensity = 0.95

scene.background.contents = NSColor.clear
let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
renderer.scene = scene
renderer.pointOfView = eye
renderer.autoenablesDefaultLighting = false

let out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for i in 0..<frames {
    let t = frames > 1 ? CGFloat(i) / CGFloat(frames - 1) : 0.5
    model.eulerAngles = SCNVector3(0.2, (t * 2 - 1) * sweep * .pi / 180, 0)
    let image = renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(String(format: "%02d.png", i)))
}
print("rendered", frames)
