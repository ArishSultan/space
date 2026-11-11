import Testing
@testable import SpaceCore

@Suite struct RecipeTests {
    @Test func builtinRecipesLoad() throws {
        let store = try RecipeStore(userDirectory: nil)
        #expect(Set(store.recipes.keys).isSuperset(of: ["postgres", "mailpit", "redis"]))
        #expect(store["postgres"]?.connectionInfo["url"] == "postgres://space:space@localhost:5432/postgres")
        #expect(store["mailpit"]?.adminURL.map { store["mailpit"]!.expand($0) } == "http://localhost:8025")
    }

    @Test func actionSubstitutesParams() throws {
        let pg = try #require(try RecipeStore(userDirectory: nil)["postgres"])
        let cmd = try #require(pg.actions?["create_db"]).command(with: ["name": "acme_dev"])
        #expect(cmd.last == #"CREATE DATABASE "acme_dev""#)
    }

    @Test func actionRejectsUnsafeParams() throws {
        let pg = try #require(try RecipeStore(userDirectory: nil)["postgres"])
        let action = try #require(pg.actions?["create_db"])
        #expect(throws: ActionError.self) { try action.command(with: ["name": #"x"; DROP DATABASE postgres; --"#]) }
        #expect(throws: ActionError.self) { try action.command(with: [:]) }
    }

    @Test func runArgumentsPublishOnLoopbackWithVolumes() throws {
        let pg = try #require(try RecipeStore(userDirectory: nil)["postgres"])
        let args = ServiceManager.runArguments(for: pg)
        #expect(args.contains("127.0.0.1:5432:5432"))
        #expect(args.contains("space-postgres-data:/var/lib/postgresql/data"))
        #expect(args.last == pg.image)
    }

    @Test func userRecipeOverridesBuiltin() throws {
        let yaml = """
        id: redis
        name: Valkey
        image: valkey/valkey:latest
        ports: [{ name: redis, container: 6379, host: 6380 }]
        """
        let r = try RecipeStore.decode(yaml)
        #expect(r.hostPort("redis") == 6380)
    }
}

@Suite struct PostgresRecipeTests {
    @Test func projectCreatesRoleAndOwnedDatabase() throws {
        let pg = try #require(try RecipeStore(userDirectory: nil)["postgres"])
        let cmd = try #require(pg.actions?["create_project"]).command(with: ["name": "shop"])
        #expect(cmd.contains(#"CREATE ROLE "shop" LOGIN CREATEDB PASSWORD 'shop'"#))
        #expect(cmd.contains(#"CREATE DATABASE "shop" OWNER "shop""#))
    }

    @Test func resourceKindsAndProtection() throws {
        let pg = try #require(try RecipeStore(userDirectory: nil)["postgres"])
        #expect(pg.resources?.map(\.id) == ["projects", "databases", "users"])
        #expect(pg.resourceKind("databases")?.protected == ["postgres", "space"])
        #expect(pg.resourceKind("projects").map { pg.expand($0.connection!) } == "postgres://{name}:{name}@localhost:5432/{name}")
    }
}

@Suite struct CatalogTests {
    @Test func allBuiltinRecipesDecodeWithLogos() throws {
        let store = try RecipeStore(userDirectory: nil)
        #expect(Set(store.recipes.keys) == ["postgres", "mailpit", "redis", "rustfs", "mongodb"])
        for id in store.recipes.keys { #expect(store.logoURL(id) != nil, "missing logo for \(id)") }
    }

    @Test func rustfsBucketActionsRunInAwsCliWithSharedEnv() throws {
        let rf = try #require(try RecipeStore(userDirectory: nil)["rustfs"])
        let create = try #require(rf.actions?["create_bucket"])
        #expect(create.image == "amazon/aws-cli:latest")
        #expect(create.env?["AWS_ENDPOINT_URL"] == "http://{address}:9000")
        #expect(rf.actions?["list_buckets"]?.env == create.env)  // YAML anchor reused
        #expect(try create.command(with: ["name": "uploads"]) == ["s3api", "create-bucket", "--bucket", "uploads"])
    }
}

@Suite struct ClientDetectionTests {
    @Test func countsEstablishedNonLoopbackConnectionsOnServicePorts() {
        // local 5432 (0x1538). Rows: established from 192.168.64.1, established from 127.0.0.1 (ignored),
        // listening (ignored), established on another port (ignored), IPv4-mapped IPv6 from 192.168.64.7.
        let proc = """
          sl  local_address rem_address   st tx_queue rx_queue
           0: 00000000:1538 00000000:0000 0A 00000000:00000000
           1: 0340A8C0:1538 0140A8C0:D2F0 01 00000000:00000000
           2: 0100007F:1538 0100007F:9C40 01 00000000:00000000
           3: 0340A8C0:1F90 0140A8C0:D2F1 01 00000000:00000000
           4: 0000000000000000FFFF00000340A8C0:1538 0000000000000000FFFF00000740A8C0:C350 01 00000000:00000000
        """
        #expect(ServiceManager.establishedPeers(procNetTCP: proc, ports: [5432]) == ["192.168.64.1", "192.168.64.7"])
    }
}
