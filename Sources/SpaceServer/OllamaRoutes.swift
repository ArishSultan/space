import Foundation
import Hummingbird
import SpaceCore

extension SpaceServer {
    /// Ollama models and settings. Paths live under /api so they also work through the remote-Mac proxy.
    static func ollamaRoutes(_ r: Router<BasicRequestContext>, services: ServiceManager) {
        let api = r.group("api/ollama")
        api.get("models") { _, _ in Reply(try await services.ollamaModels()) }
        api.post("models/pull") { req, ctx in
            try await services.ollamaPull(try await req.decode(as: OllamaNameRequest.self, context: ctx).name)
            return Reply(OK())
        }
        api.post("models/load") { req, ctx in
            try await services.ollamaLoad(try await req.decode(as: OllamaNameRequest.self, context: ctx).name)
            return Reply(OK())
        }
        api.post("models/unload") { req, ctx in
            try await services.ollamaUnload(try await req.decode(as: OllamaNameRequest.self, context: ctx).name)
            return Reply(OK())
        }
        // DELETE /api/ollama/models?name=llama3.2:latest (model names contain ':' and '/')
        api.delete("models") { req, _ in
            guard let name = req.uri.queryParameters.get("name") else { throw HTTPError(.badRequest, message: "Missing 'name'") }
            try await services.ollamaDelete(name)
            return Reply(OK())
        }
        api.get("pulls") { _, _ in Reply(await services.ollamaPulls()) }
        api.post("pulls/cancel") { req, ctx in
            try await services.ollamaCancelPull(try await req.decode(as: OllamaNameRequest.self, context: ctx).name)
            return Reply(OK())
        }
        api.get("settings") { _, _ in Reply(await services.ollamaSettings()) }
        api.post("settings") { req, ctx in
            Reply(try await services.setOllamaSettings(try await req.decode(as: OllamaSettings.self, context: ctx)))
        }
    }
}
