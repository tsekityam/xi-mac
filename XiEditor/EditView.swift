// Copyright 2016 Google Inc. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Cocoa

extension NSFont {
    /// If the font is monospace, returns the width of a character, else returns 0.
    func characterWidth() -> CGFloat {
        if self.isFixedPitch {
            let characters = [UniChar(0x20)]
            var glyphs = [CGGlyph(0)]
            if CTFontGetGlyphsForCharacters(self, characters, &glyphs, 1) {
                let advance = CTFontGetAdvancesForGlyphs(self, .horizontal, glyphs, nil, 1)
                return CGFloat(advance)
            }
        }
        return 0
    }
}

/// A store of properties used to determine the layout of text.
struct TextDrawingMetrics {
    let font: NSFont
    var attributes: [String: AnyObject] = [:]
    var ascent: CGFloat
    var descent: CGFloat
    var leading: CGFloat
    var baseline: CGFloat
    var linespace: CGFloat
    var fontWidth: CGFloat
    
    init(font: NSFont) {
        self.font = font
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        leading = CTFontGetLeading(font)
        linespace = ceil(ascent + descent + leading)
        baseline = ceil(ascent)
        fontWidth = font.characterWidth()
        attributes[String(kCTFontAttributeName)] = font
    }
    
    /// Passed an NSFontManager instance (as on a user-initiated font change) computes the next set of drawing metrics.
    func newMetricsForFontChange(fontManager: NSFontManager) -> TextDrawingMetrics {
        let newFont = fontManager.convert(font)
        return TextDrawingMetrics(font: newFont)
    }
}

/// A line-column index into a displayed text buffer.
typealias BufferPosition = (line: Int, column: Int)


func insertedStringToJson(_ stringToInsert: NSString) -> Any {
    return ["chars": stringToInsert]
}

func colorFromArgb(_ argb: UInt32) -> NSColor {
    return NSColor(red: CGFloat((argb >> 16) & 0xff) * 1.0/255,
        green: CGFloat((argb >> 8) & 0xff) * 1.0/255,
        blue: CGFloat(argb & 0xff) * 1.0/255,
        alpha: CGFloat((argb >> 24) & 0xff) * 1.0/255)
}

func camelCaseToUnderscored(_ name: NSString) -> NSString {
    let underscored = NSMutableString();
    let scanner = Scanner(string: name as String);
    let notUpperCase = CharacterSet.uppercaseLetters.inverted;
    var notUpperCaseFragment: NSString?
    while (scanner.scanUpToCharacters(from: CharacterSet.uppercaseLetters, into: &notUpperCaseFragment)) {
        underscored.append(notUpperCaseFragment! as String);
        var upperCaseFragement: NSString?
        if (scanner.scanUpToCharacters(from: notUpperCase, into: &upperCaseFragement)) {
            underscored.append("_");
            let downcasedFragment = upperCaseFragement!.lowercased;
            underscored.append(downcasedFragment);
        }
    }
    return underscored;
}

class EditView: NSView, NSTextInputClient {
    var dataSource: EditViewDataSource!

    var textSelectionColor: NSColor {
        if self.isFrontmostView {
            return NSColor.selectedTextBackgroundColor
        } else {
        return NSColor(colorLiteralRed: 0.8, green: 0.8, blue: 0.8, alpha: 1.0)
        }
    }

    var lastDragLineCol: (Int, Int)?
    var timer: Timer?
    var timerEvent: NSEvent?

    fileprivate var _selectedRange: NSRange
    fileprivate var _markedRange: NSRange
    
    var isFrontmostView = false {
        didSet {
            //TODO: blinking should one day be a user preference
            showBlinkingCursor = isFrontmostView
            self.needsDisplay = true
        }
    }
    
    /*  Insertion point blinking.
     Only the frontmost ('key') window should have a blinking insertion point.
     A new 'on' cycle starts every time the window comes to the front, or the text changes, or the ins. point moves.
     Type fast enough and the ins. point stays on.
     */
    var _blinkTimer : Timer?
    private var _cursorStateOn = false
    /// if set to true, this view will show blinking cursors
    var showBlinkingCursor = false {
        didSet {
            _cursorStateOn = showBlinkingCursor
            _blinkTimer?.invalidate()
            if showBlinkingCursor {
                _blinkTimer = Timer.scheduledTimer(timeInterval: TimeInterval(1.0), target: self, selector: #selector(_blinkInsertionPoint), userInfo: nil, repeats: true)
            } else {
                _blinkTimer = nil
            }
        }
    }
    
    private var cursorColor: CGColor {
        return _cursorStateOn ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
    }
    
    required init?(coder: NSCoder) {
        
        _selectedRange = NSMakeRange(NSNotFound, 0)
        _markedRange = NSMakeRange(NSNotFound, 0)
        super.init(coder: coder)
    }

    let x0: CGFloat = 2;

    let font_style_bold: Int = 1;
    let font_style_underline: Int = 2;
    let font_style_italic: Int = 4;

    override func draw(_ dirtyRect: NSRect) {
        if dataSource.document.coreViewIdentifier == nil { return }
        super.draw(dirtyRect)
        /*
        let path = NSBezierPath(ovalInRect: frame)
        NSColor(colorLiteralRed: 0, green: 0, blue: 1, alpha: 0.25).setFill()
        path.fill()
        let path2 = NSBezierPath(ovalInRect: dirtyRect)
        NSColor(colorLiteralRed: 0, green: 0.5, blue: 0, alpha: 0.25).setFill()
        path2.fill()
        */

        let context = NSGraphicsContext.current()!.cgContext
        let first = Int(floor(dirtyRect.origin.y / dataSource.textMetrics.linespace))
        let last = Int(ceil((dirtyRect.origin.y + dirtyRect.size.height) / dataSource.textMetrics.linespace))

        let missing = dataSource.lines.computeMissing(first, last)
        for (f, l) in missing {
            Swift.print("requesting missing: \(f)..\(l)")
            dataSource.document.sendRpcAsync("request_lines", params: [f, l])
        }

        // first pass, for drawing background selections
        _selectedRange = NSMakeRange(NSNotFound, 0)
        var lineStartPos = 0 as Int
        for lineIx in first..<last {
            guard let line = getLine(lineIx) else { continue }
            if (line.containsSelection == true) {
                let selections = line.styles.filter { $0.style == 0 }
                let attrString = NSMutableAttributedString(string: line.text, attributes: dataSource.textMetrics.attributes)
                let ctline = CTLineCreateWithAttributedString(attrString)
                let y = dataSource.textMetrics.linespace * CGFloat(lineIx + 1)
                context.setFillColor(textSelectionColor.cgColor)
                for selection in selections {
                    let selStart = CTLineGetOffsetForStringIndex(ctline, selection.range.location, nil)
                    let selEnd = CTLineGetOffsetForStringIndex(ctline, selection.range.location + selection.range.length, nil)
                    context.fill(CGRect.init(x: x0 + selStart, y: y - dataSource.textMetrics.ascent, width: selEnd - selStart, height: dataSource.textMetrics.linespace))
                    _selectedRange = NSMakeRange(lineStartPos + selection.range.location, selection.range.length)
                }
            }
            let s = line.text
            lineStartPos += s.characters.count
        }
        // second pass, for actually rendering text.
        lineStartPos = 0
        for lineIx in first..<last {
            // TODO: could block for ~1ms waiting for missing lines to arrive
            guard let line = getLine(lineIx) else { continue }
            let s = line.text
            var attrString = NSMutableAttributedString(string: s, attributes: dataSource.textMetrics.attributes)
            /*
            let randcolor = NSColor(colorLiteralRed: Float(drand48()), green: Float(drand48()), blue: Float(drand48()), alpha: 1.0)
            attrString.addAttribute(NSForegroundColorAttributeName, value: randcolor, range: NSMakeRange(0, s.utf16.count))
            */
            dataSource.styleMap.applyStyles(text: s, string: &attrString, styles: line.styles)
            for c in line.cursor {
                // TODO: How should we handle the situations that have multi-cursor?
                let cix = utf8_offset_to_utf16(s, c)
                if (_selectedRange.location == NSNotFound) {
                    _selectedRange = NSMakeRange(lineStartPos + cix, 0)
                }
                // Assume that the marked text is in the line same as the cursor.
                if (_markedRange.location != NSNotFound) {
                    if (_markedRange.location - lineStartPos + _markedRange.length > s.characters.count) {
                        // TODO: although the insert marked text request is sent to backend and the marked range is updated in frontend, however, the text may not be added to backend. If we try to add attribute to those text not yet added to backend, the app will crash.
                        continue
                    }
                    attrString.addAttribute(NSUnderlineStyleAttributeName,
                                                value: NSUnderlineStyle.styleSingle.rawValue,
                                                range: NSMakeRange(_markedRange.location - lineStartPos, _markedRange.length))
                }
            }

            // TODO: I don't understand where the 13 comes from (it's what aligns with baseline. We
            // probably want to move to using CTLineDraw instead of drawing the attributed string,
            // but that means drawing the selection highlight ourselves (which has other benefits).
            //attrString.drawAtPoint(NSPoint(x: x0, y: y - 13))
            let y = dataSource.textMetrics.linespace * CGFloat(lineIx + 1);
            attrString.draw(with: NSRect(x: x0, y: y, width: dirtyRect.origin.x + dirtyRect.width - x0, height: 14), options: [])
            if showBlinkingCursor {
                for cursor in line.cursor {
                    let ctline = CTLineCreateWithAttributedString(attrString)
                    /*
                    CGContextSetTextMatrix(context, CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x0, ty: y))
                    CTLineDraw(ctline, context)
                    */
                    var pos = CGFloat(0)
                    // special case because measurement is so expensive; might have to rethink in rtl
                    if cursor != 0 {
                        let utf16_ix = utf8_offset_to_utf16(s, cursor)
                        pos = CTLineGetOffsetForStringIndex(ctline, CFIndex(utf16_ix), nil)
                    }
                    context.setStrokeColor(cursorColor)
                    context.move(to: CGPoint(x: x0 + pos, y: y + dataSource.textMetrics.descent))
                    context.addLine(to: CGPoint(x: x0 + pos, y: y - dataSource.textMetrics.ascent))
                    context.strokePath()
                }
            }
            lineStartPos += s.characters.count
        }
    }

    override var acceptsFirstResponder: Bool {
        return true;
    }

    // we use a flipped coordinate system primarily to get better alignment when scrolling
    override var isFlipped: Bool {
        return true;
    }
    
    // MARK: - NSTextInputClient protocol
    func insertText(_ aString: Any, replacementRange: NSRange) {
        var rangeToBeReplace = replacementRange
        if (replacementRange.location == NSNotFound) {
            if (_markedRange.location != NSNotFound) {
                rangeToBeReplace = _markedRange
            } else {
                rangeToBeReplace = _selectedRange;
            }
        }
        let _ = self.replaceCharactersInRange(rangeToBeReplace, withText: aString as AnyObject)
        self.unmarkText()
    }

    public func characterIndex(for point: NSPoint) -> Int {
        return 0
    }
    
    func replaceCharactersInRange(_ aRange: NSRange, withText aString: AnyObject) -> NSRange {
        var replacementRange = aRange
        var len = 0
        if let attrStr = aString as? NSAttributedString {
            len = attrStr.string.characters.count
        } else if let str = aString as? NSString {
            len = str.length
        }
        if (replacementRange.location == NSNotFound) {
            replacementRange.location = 0
            replacementRange.length = 0
        }
        for _ in 0..<aRange.length {
            dataSource.document.sendRpcAsync("delete_backward", params  : [])
        }
        if let attrStr = aString as? NSAttributedString {
            dataSource.document.sendRpcAsync("insert", params: insertedStringToJson(attrStr.string as NSString))
        } else if let str = aString as? NSString {
            dataSource.document.sendRpcAsync("insert", params: insertedStringToJson(str))
        }
        // TODO: update selected range here
        return NSMakeRange(replacementRange.location, len)
    }

    func setMarkedText(_ aString: Any, selectedRange: NSRange, replacementRange: NSRange) {
        var rangeToBeReplace = replacementRange
        if (replacementRange.location == NSNotFound) {
            if (_markedRange.location != NSNotFound) {
                rangeToBeReplace = _markedRange
            } else {
                rangeToBeReplace = _selectedRange;
            }
        }
        _markedRange = self.replaceCharactersInRange(rangeToBeReplace, withText: aString as AnyObject)
        if (_markedRange.length == 0) {
            unmarkText();
        }
    }

    func removeMarkedText() {
        if (_markedRange.location != NSNotFound) {
            for _ in 0..<_markedRange.length {
                dataSource.document.sendRpcAsync("delete_backward", params: [])
            }
        }
        _markedRange = NSMakeRange(NSNotFound, 0)
    }

    func unmarkText() {
        self._markedRange = NSMakeRange(NSNotFound, 0)
    }

    func selectedRange() -> NSRange {
        return _selectedRange
    }

    func markedRange() -> NSRange {
        return _markedRange
    }

    func hasMarkedText() -> Bool {
        return _markedRange.location != NSNotFound
    }

    func attributedSubstring(forProposedRange aRange: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return NSAttributedString()
    }

    func validAttributesForMarkedText() -> [String] {
        return [NSForegroundColorAttributeName, NSBackgroundColorAttributeName]
    }

    func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let lineIx = getLineOfPos(aRange.location)
        let pos = aRange.location - getLineStartPos(lineIx)
        if let viewWinFrame = self.window?.convertToScreen(self.frame),
            let line = getLine(lineIx) {
            let str = line.text
            let ctLine = CTLineCreateWithAttributedString(NSMutableAttributedString(string: str, attributes: dataSource.textMetrics.attributes))
            let rangeWidth = CTLineGetOffsetForStringIndex(ctLine, pos, nil) - CTLineGetOffsetForStringIndex(ctLine, pos - aRange.length, nil)
            return NSRect(x: viewWinFrame.origin.x + CTLineGetOffsetForStringIndex(ctLine, pos, nil),
                          y: viewWinFrame.origin.y + viewWinFrame.size.height - dataSource.textMetrics.linespace * CGFloat(lineIx + 1) - 5,
                          width: rangeWidth,
                          height: dataSource.textMetrics.linespace)
        } else {
            return NSRect(x: 0, y: 0, width: 0, height: 0)
        }
    }

    /// MARK: - System Events
    
    override func doCommand(by aSelector: Selector) {
        if (self.responds(to: aSelector)) {
            super.doCommand(by: aSelector);
        } else {
            let commandName = camelCaseToUnderscored(aSelector.description as NSString).replacingOccurrences(of: ":", with: "");
            if (commandName == "noop") {
                NSBeep()
            } else {
                dataSource.document.sendRpcAsync(commandName, params: []);
            }
        }
    }
    
    /// timer callback to toggle the blink state
    func _blinkInsertionPoint() {
        _cursorStateOn = !_cursorStateOn
        needsDisplay = true
    }

    // TODO: more functions should call this, just dividing by linespace doesn't account for descent
    func yToLine(_ y: CGFloat) -> Int {
        return Int(floor(max(y - dataSource.textMetrics.descent, 0) / dataSource.textMetrics.linespace))
    }

    func lineIxToBaseline(_ lineIx: Int) -> CGFloat {
        return CGFloat(lineIx + 1) * dataSource.textMetrics.linespace
    }

    /// given a point in the containing window's coordinate space, converts it into a line / column position in the current view.
    /// Note: - The returned position is not guaruanteed to be an existing line. For instance, if a buffer does not fill the current window, a point below the last line will return a buffer position with a line number exceeding the number of lines in the file. In this case position.column will always be zero.
    func bufferPositionFromPoint(_ point: NSPoint) -> BufferPosition {
        let point = self.convert(point, from: nil)
        let lineIx = yToLine(point.y)
        if let line = getLine(lineIx) {
            let s = line.text
            let attrString = NSAttributedString(string: s, attributes: dataSource.textMetrics.attributes)
            let ctline = CTLineCreateWithAttributedString(attrString)
            let relPos = NSPoint(x: point.x - x0, y: lineIxToBaseline(lineIx) - point.y)
            let utf16_ix = CTLineGetStringIndexForPosition(ctline, relPos)
            if utf16_ix != kCFNotFound {
                let col = utf16_offset_to_utf8(s, utf16_ix)
                return BufferPosition(line: lineIx, column: col)
            }
        }
        return BufferPosition(line: lineIx, column: 0)
    }

    private func utf8_offset_to_utf16(_ s: String, _ ix: Int) -> Int {
        // String(s.utf8.prefix(ix)).utf16.count
        return s.utf8.index(s.utf8.startIndex, offsetBy: ix).samePosition(in: s.utf16)!._offset
    }
    
    private func utf16_offset_to_utf8(_ s: String, _ ix: Int) -> Int {
        return String(describing: s.utf16.prefix(ix)).utf8.count
    }

    func getLine(_ lineNum: Int) -> Line? {
        return dataSource.lines.get(lineNum)
    }

    func getLineOfPos(_ pos: Int) -> Int {
        var lineNum = 0 as Int
        
        var wordCount = 0 as Int
        while true {
            var line = getLine(lineNum)
            if (line == nil) {
                break
            }
            wordCount += (line?.text.characters.count)!
            if (wordCount >= pos) {
                break
            }
            lineNum += 1
        }
        
        return lineNum
    }

    func getLineStartPos(_ lineNum: Int) -> Int {
        var wordCount = 0 as Int
        
        if (lineNum == 0) {
            return 0
        }
        
        for lineIx in 0...lineNum-1 {
            var line = getLine(lineIx)
            if (line == nil) {
                break
            }
            wordCount += (line?.text.characters.count)!
        }
        
        return wordCount
    }
}
