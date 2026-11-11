import Foundation
import Testing
@testable import SpaceCore
@testable import SpaceNet

@Suite struct ProjectEnvTests {
    private let recipes: [String: Recipe] = {
        let store = try! RecipeStore(userDirectory: nil)
        return Dictionary(uniqueKeysWithValues: store.recipes.map { ($0.key, $0.value) })
    }()

    @Test func endpointsAndLinkedResourcesFormTheEnv() {
        let project = SpaceState.Project(
            name: "proposal-generator",
            endpoints: [.init(name: "api", port: 3100, hostname: "api.proposal-generator"),
                        .init(name: "portal", port: 3101, hostname: "portal.proposal-generator")],
            resources: [.init(service: "postgres", kind: "databases", name: "proposals"),
                        .init(service: "s3", kind: "buckets", name: "uploads"),
                        .init(service: "redis")])
        let env = Projects.env(project: project, routerPort: 80, recipes: recipes)
        #expect(env.contains("PORT=3100"))
        #expect(env.contains("APP_URL=http://api.proposal-generator.localhost"))
        #expect(env.contains("PORTAL_PORT=3101"))
        #expect(env.contains("PORTAL_URL=http://portal.proposal-generator.localhost"))
        #expect(env.contains("DATABASE_URL=postgres://space:space@localhost:5432/proposals"))
        #expect(env.contains("S3_BUCKET=uploads"))
        #expect(env.contains("REDIS_URL=redis://localhost:6379"))
    }

    @Test func secondDatabaseGetsAPrefixedVariable() {
        let project = SpaceState.Project(
            name: "shop",
            resources: [.init(service: "postgres", kind: "databases", name: "main"),
                        .init(service: "postgres", kind: "dbusers", name: "analytics")])
        let env = Projects.env(project: project, routerPort: 80, recipes: recipes)
        #expect(env.contains("\nDATABASE_URL=postgres://space:space@localhost:5432/main"))
        #expect(env.contains("ANALYTICS_DATABASE_URL=postgres://analytics:analytics@localhost:5432/analytics"))
    }

    @Test func linksToUsersAddNothing() {
        let project = SpaceState.Project(name: "shop", resources: [.init(service: "postgres", kind: "users", name: "bob")])
        #expect(!Projects.env(project: project, routerPort: 80, recipes: recipes).contains("bob"))
    }

    @Test func oldProjectShapeStillDecodes() throws {
        let json = #"{"name": "legacy", "services": ["postgres"], "ports": {"web": 3100}}"#
        let p = try JSONDecoder().decode(SpaceState.Project.self, from: Data(json.utf8))
        #expect(p.name == "legacy" && p.endpoints.isEmpty && p.resources.isEmpty)
    }
}
