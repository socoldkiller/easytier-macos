package actor GatewayDatabaseConfigurationStore: GatewayConfigurationStoring {
    private let database: ApplicationDatabase

    package init(database: ApplicationDatabase) {
        self.database = database
    }

    package func load() async throws -> GatewayPersistedState? {
        try await database.loadGateway()
    }

    package func save(_ state: GatewayPersistedState) async throws {
        try await database.saveGateway(state)
    }
}
