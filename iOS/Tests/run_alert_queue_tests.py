from pathlib import Path
import subprocess,tempfile
source=(Path(__file__).resolve().parents[1]/'MultiChatViewer/AlertPlaybackQueue.swift').read_text()
source=source[source.index('final class AlertPlaybackQueue:'):source.index('struct AlertQueueStatusView:')]
stubs=r'''
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<T> { var wrappedValue:T }
final class WKWebView {
    var calls:[String]=[]
    var suspends:[()->Void]=[]
    func setAllMediaPlaybackSuspended(_ value:Bool, completionHandler: @escaping ()->Void) {
        if value { suspends.append(completionHandler) } else { completionHandler() }
    }
    func evaluateJavaScript(_ script:String, completionHandler: ((Any?,Error?)->Void)?) {
        calls.append(script);completionHandler?(nil,nil)
    }
    func ack() { let callbacks=suspends;suspends=[];callbacks.forEach {$0()} }
}
'''
tests=r'''
let queue=AlertPlaybackQueue()
let a=UUID(), b=UUID(), c=UUID()
let wa=WKWebView(),wb=WKWebView(),wc=WKWebView()
for (id,web) in [(a,wa),(b,wb),(c,wc)] {queue.register(id,web:web,show:{_ in});web.ack()}
func event(_ type:String,_ seq:Int=1)->String { "{\"type\":\"\(type)\",\"sequence\":\(seq)}" }
queue.receive(event("request"),source:a)
queue.receive(event("request"),source:b)
queue.receive(event("request"),source:c)
precondition(wa.calls.contains("window.__mcAlertQueue?.grant(1)"))
precondition(!wb.calls.contains("window.__mcAlertQueue?.grant(1)"))
queue.receive(event("done"),source:b)
precondition(!wb.calls.contains("window.__mcAlertQueue?.grant(1)"))
queue.receive(event("done"),source:a)
precondition(wb.calls.contains("window.__mcAlertQueue?.grant(1)"))
queue.unregister(b,after:{})
precondition(wc.calls.contains("window.__mcAlertQueue?.grant(1)"))
queue.receive(event("done"),source:b)
queue.receive(event("done"),source:c);wc.ack()
precondition(queue.status.contains("待機中"))
queue.receive(event("request"),source:c)
precondition(wc.calls.filter {$0=="window.__mcAlertQueue?.grant(1)"}.count==1)
print("PASS: iPhone FIFO, stale completion, duplicate admission and removal without global media suspension")
'''
with tempfile.TemporaryDirectory() as folder:
    path=Path(folder)/'main.swift';path.write_text(stubs+source+tests)
    binary=Path(folder)/'queue-tests'
    subprocess.run(['swiftc',str(path),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,timeout=30)
