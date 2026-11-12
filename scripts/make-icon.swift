// Dibuja el ícono de mercury-recorder (1024×1024 PNG).
// Uso: swift scripts/make-icon.swift <salida.png>
// Diseño: placa redondeada azul noche con brillo plateado, una onda de sonido
// en barras plateadas ("mercurio") y un punto rojo de grabación.
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

// Lienzo de exactamente 1024×1024 píxeles (sin depender de la pantalla Retina).
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("sin contexto") }
NSGraphicsContext.current = graphics
let ctx = graphics.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let space = CGColorSpaceCreateDeviceRGB()

// Placa: 824×824 centrada (cuadrícula de íconos de macOS), esquinas redondeadas.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Sombra suave debajo de la placa.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(platePath)
ctx.setFillColor(color(0x0B1226))
ctx.fillPath()
ctx.restoreGState()

// Fondo: degradado azul noche → índigo.
ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
let background = CGGradient(colorsSpace: space,
                            colors: [color(0x0B1226), color(0x1B2A5E), color(0x3B3F8F)] as CFArray,
                            locations: [0, 0.55, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])

// Brillo plateado diagonal en la parte superior.
let sheen = CGGradient(colorsSpace: space,
                       colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 330, y: 860), startRadius: 0,
                       endCenter: CGPoint(x: 330, y: 860), endRadius: 620, options: [])
ctx.restoreGState()

// Onda de sonido: barras redondeadas con degradado plateado.
let heights: [CGFloat] = [150, 270, 420, 560, 420, 300, 190]
let barWidth: CGFloat = 62
let gap: CGFloat = 30
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (size - totalWidth) / 2
let centerY: CGFloat = 488
let silver = CGGradient(colorsSpace: space,
                        colors: [color(0xFFFFFF), color(0xD7DCE6), color(0x9AA3B5)] as CFArray,
                        locations: [0, 0.5, 1])!
for height in heights {
    let bar = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
    let path = CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x000000, 0.35))
    ctx.addPath(path)
    ctx.setFillColor(color(0xC9CFDB))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(silver, start: CGPoint(x: bar.minX, y: bar.maxY), end: CGPoint(x: bar.maxX, y: bar.minY), options: [])
    ctx.restoreGState()
    x += barWidth + gap
}

// Punto rojo de grabación, arriba a la derecha, con halo.
let dotCenter = CGPoint(x: 790, y: 790)
let halo = CGGradient(colorsSpace: space,
                      colors: [color(0xFF3B30, 0.45), color(0xFF3B30, 0)] as CFArray, locations: [0, 1])!
// El halo se recorta a la placa para que no se salga por la esquina.
ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
ctx.drawRadialGradient(halo, startCenter: dotCenter, startRadius: 0, endCenter: dotCenter, endRadius: 120, options: [])
ctx.restoreGState()
let dot = CGRect(x: dotCenter.x - 54, y: dotCenter.y - 54, width: 108, height: 108)
let red = CGGradient(colorsSpace: space,
                     colors: [color(0xFF6B5E), color(0xE5281C)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: dot)
ctx.clip()
ctx.drawLinearGradient(red, start: CGPoint(x: dot.minX, y: dot.maxY), end: CGPoint(x: dot.maxX, y: dot.minY), options: [])
ctx.restoreGState()
ctx.addEllipse(in: dot.insetBy(dx: 2, dy: 2))
ctx.setStrokeColor(color(0xFFFFFF, 0.35))
ctx.setLineWidth(4)
ctx.strokePath()

graphics.flushGraphics()
NSGraphicsContext.current = nil

guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("no se pudo generar el PNG") }
try png.write(to: URL(fileURLWithPath: output))
print("Ícono: \(output) (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh))")
