import AppKit
import CoreText

let url = URL(fileURLWithPath: CommandLine.arguments[1])
var bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
let context = CGContext(url as CFURL, mediaBox: &bounds, nil)!
for number in 1...2 {
    context.beginPDFPage(nil)
    let heading = NSAttributedString(string: "Docling Mac PDF Check \(number)", attributes: [
        .font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor.black
    ])
    context.textPosition = CGPoint(x: 50, y: 755)
    CTLineDraw(CTLineCreateWithAttributedString(heading), context)
    let body = NSAttributedString(string: "Native PDF text remains searchable.\n本地文档转换验收。\n\nReading order and content should be preserved.", attributes: [
        .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black
    ])
    let path = CGPath(rect: CGRect(x: 50, y: 400, width: 495, height: 300), transform: nil)
    CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(body), CFRange(location: 0, length: 0), path, nil), context)
    context.endPDFPage()
}
context.closePDF()
