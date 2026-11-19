import Cocoa

// MiddleMove: hold the middle mouse button over any window and move the mouse to
// drag that window. A plain middle click (press and release without moving) still
// reaches the app as usual, e.g. to close a browser tab or open a link in a new tab.

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
