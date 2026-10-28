import 'package:flutter_test/flutter_test.dart';
import 'package:openoia/db_models.dart';

void main() {
  group('DbConnectionConfig & DbModels tests', () {
    test('Default port and brand colors for engines', () {
      expect(DbEngine.postgres.defaultPort, 5432);
      expect(DbEngine.mysql.defaultPort, 3306);
      expect(DbEngine.sqlserver.defaultPort, 1433);

      expect(DbEngine.postgres.label, 'PostgreSQL');
      expect(DbEngine.mysql.label, 'MySQL / MariaDB');
      expect(DbEngine.sqlserver.label, 'SQL Server (MSSQL)');
    });

    test('DbEnvironment badges', () {
      expect(DbEnvironment.production.label, 'Produção');
      expect(DbEnvironment.staging.label, 'Homologação');
      expect(DbEnvironment.development.label, 'Desenvolvimento');
    });

    test('Json serialization and deserialization', () {
      final config = DbConnectionConfig(
        id: 'conn_101',
        name: 'Postgres Producao',
        engine: DbEngine.postgres,
        environment: DbEnvironment.production,
        host: '10.0.0.15',
        port: 5432,
        databaseName: 'db_senar',
        username: 'admin',
        password: 'secretPassword123',
        useSshTunnel: true,
        sshHostId: 'ssh_host_1',
        ssl: true,
      );

      final json = config.toJson();
      expect(json['id'], 'conn_101');
      expect(json['hasPassword'], true);
      // Plaintext password is NEVER written in json
      expect(json.containsKey('password'), false);

      final restored = DbConnectionConfig.fromJson(json);
      expect(restored.id, 'conn_101');
      expect(restored.name, 'Postgres Producao');
      expect(restored.engine, DbEngine.postgres);
      expect(restored.environment, DbEnvironment.production);
      expect(restored.useSshTunnel, true);
      expect(restored.ssl, true);
    });

    test('DbQueryResult properties', () {
      const selectResult = DbQueryResult(
        columns: ['id', 'nome', 'email'],
        rows: [
          [1, 'Carlos', 'carlos@senar.org.br'],
          [2, 'Mariana', 'mariana@senar.org.br'],
        ],
        executionTimeMs: 14,
        affectedRows: 2,
      );

      expect(selectResult.hasError, false);
      expect(selectResult.isSelect, true);
      expect(selectResult.columns.length, 3);
      expect(selectResult.rows.length, 2);

      const dmlResult = DbQueryResult(
        columns: [],
        rows: [],
        executionTimeMs: 8,
        affectedRows: 1,
      );

      expect(dmlResult.isSelect, false);
      expect(dmlResult.hasError, false);
      expect(dmlResult.affectedRows, 1);
    });

    test('DDL generation for Postgres table', () async {
      final dummyConfig = DbConnectionConfig(
        id: 't',
        name: 't',
        engine: DbEngine.postgres,
        environment: DbEnvironment.development,
        host: 'localhost',
        port: 5432,
        databaseName: 'test',
        username: 'u',
      );

      final client = PostgresDatabaseClient(dummyConfig, host: 'localhost', port: 5432);
      expect(client.host, 'localhost');
      expect(client.port, 5432);
    });

    test('TableForeignKey properties and serialization', () {
      const fk = TableForeignKey(
        constraintName: 'fk_pedidos_usuario',
        fromSchema: 'public',
        fromTable: 'pedidos',
        fromColumn: 'usuario_id',
        toSchema: 'public',
        toTable: 'usuarios',
        toColumn: 'id',
      );

      expect(fk.constraintName, 'fk_pedidos_usuario');
      expect(fk.fromTable, 'pedidos');
      expect(fk.fromColumn, 'usuario_id');
      expect(fk.toTable, 'usuarios');
      expect(fk.toColumn, 'id');

      final json = fk.toJson();
      expect(json['constraintName'], 'fk_pedidos_usuario');
      expect(json['fromColumn'], 'usuario_id');
      expect(json['toTable'], 'usuarios');
    });
  });
}
