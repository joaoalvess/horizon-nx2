import Foundation

@main
struct ReceiverMain {
    @MainActor
    static func main() {
        let options: ReceiverOptions
        do {
            options = try ReceiverOptions.parse(Array(CommandLine.arguments.dropFirst()))
        } catch let error as OptionError {
            Console.error(error.message)
            Console.error(ReceiverOptions.usage)
            exit(2)
        } catch {
            Console.error("\(error)")
            exit(2)
        }
        if options.help {
            Console.line(ReceiverOptions.usage)
            exit(0)
        }
        let receiver: Receiver
        do {
            receiver = try Receiver(options: options)
        } catch let error as OptionError {
            Console.error(error.message)
            exit(1)
        } catch {
            Console.error("the receiver did not start: \(error)")
            exit(1)
        }
        if options.window {
            let window = ReceiverWindow(receiver: receiver)
            receiver.start()
            window.run()
        }
        receiver.start()
        dispatchMain()
    }
}
