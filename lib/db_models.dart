import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mssql/mssql.dart';
import 'package:mysql_client/mysql_client.dart';
import 'package:postgres/postgres.dart' as pg;
import 'secure_storage.dart';

/// Database Engine Type
enum DbEngine {
  postgres,
  mysql,
  sqlserver;

  String get label {
    switch (this) {
      case DbEngine.postgres:
        return 'PostgreSQL';
      case DbEngine.mysql:
        return 'MySQL / MariaDB';
      case DbEngine.sqlserver:
        return 'SQL Server (MSSQL)';
    }
  }

  int get defaultPort {
    switch (this) {
      case DbEngine.postgres:
        return 5432;
      case DbEngine.mysql:
        return 3306;
      case DbEngine.sqlserver:
        return 1433;
    }
  }

  Color get brandColor {
    switch (this) {
      case DbEngine.postgres:
        return const Color(0xFF336791);
      case DbEngine.mysql:
        return const Color(0xFFF29111);
      case DbEngine.sqlserver:
        return const Color(0xFFCC292B);
    }
  }

  IconData get iconData {
    switch (this) {
      case DbEngine.postgres:
        return Icons.dns_rounded;
      case DbEngine.mysql:
        return Icons.storage_rounded;
      case DbEngine.sqlserver:
        return Icons.table_view_rounded;
    }
  }
}

/// Environment Badge (DBeaver style: Prod / Homo / Dev)
enum DbEnvironment {
  production,
  staging,
  development;

  String get label {
    switch (this) {
      case DbEnvironment.production:
        return 'Produção';
      case DbEnvironment.staging:
        return 'Homologação';
      case DbEnvironment.development:
        return 'Desenvolvimento';
    }
  }

  Color get color {
    switch (this) {
      case DbEnvironment.production:
        return const Color(0xFFEF4444);
      case DbEnvironment.staging:
        return const Color(0xFFF59E0B);
      case DbEnvironment.development:
        return const Color(0xFF10B981);
    }
  }
}

/// Metadata for a table column
class TableColumnMetadata {
  final String name;
  final String dataType;
  final bool isNullable;
  final bool isPrimaryKey;
  final bool isForeignKey;
  final String? defaultValue;

  const TableColumnMetadata({
    required this.name,
    required this.dataType,
    this.isNullable = true,
    this.isPrimaryKey = false,
    this.isForeignKey = false,
    this.defaultValue,
  });
}

/// Metadata for a Foreign Key relation
class TableForeignKey {
  final String constraintName;
  final String fromSchema;
  final String fromTable;
  final String fromColumn;
  final String toSchema;
  final String toTable;
  final String toColumn;

  const TableForeignKey({
    required this.constraintName,
    required this.fromSchema,
    required this.fromTable,
    required this.fromColumn,
    required this.toSchema,
    required this.toTable,
    required this.toColumn,
  });

  Map<String, dynamic> toJson() => {
    'constraintName': constraintName,
    'fromSchema': fromSchema,
    'fromTable': fromTable,
    'fromColumn': fromColumn,
    'toSchema': toSchema,
    'toTable': toTable,
    'toColumn': toColumn,
  };
}

/// Query Execution Result
class DbQueryResult {
  final List<String> columns;
  final List<List<dynamic>> rows;
  final int executionTimeMs;
  final int affectedRows;
  final String? error;

  const DbQueryResult({
    this.columns = const [],
    this.rows = const [],
    this.executionTimeMs = 0,
    this.affectedRows = 0,
    this.error,
  });

  bool get hasError => error != null && error!.isNotEmpty;
  bool get isSelect => columns.isNotEmpty;
}

/// Saved Connection Configuration
class DbConnectionConfig {
  final String id;
  String name;
  DbEngine engine;
  DbEnvironment environment;
  String host;
  int port;
  String databaseName;
  String username;
  String password;
  bool hasPassword;
  bool useSshTunnel;
  String sshHostId;
  bool ssl;

  DbConnectionConfig({
    required this.id,
    required this.name,
    required this.engine,
    required this.environment,
    required this.host,
    required this.port,
    required this.databaseName,
    required this.username,
    this.password = '',
    this.hasPassword = false,
    this.useSshTunnel = false,
    this.sshHostId = '',
    this.ssl = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'engine': engine.name,
      'environment': environment.name,
      'host': host,
      'port': port,
      'databaseName': databaseName,
      'username': username,
      'hasPassword': password.isNotEmpty || hasPassword,
      'useSshTunnel': useSshTunnel,
      'sshHostId': sshHostId,
      'ssl': ssl,
    };
  }

  factory DbConnectionConfig.fromJson(
    Map<String, dynamic> json, {
    SecureStorageVault? vault,
  }) {
    final id = json['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString();
    var pass = '';
    final hasPass = json['hasPassword'] == true;
    if (vault != null && hasPass) {
      pass = vault.getSecret('db_pass_$id');
    }

    DbEngine eng = DbEngine.postgres;
    final engStr = json['engine']?.toString();
    if (engStr == 'mysql') eng = DbEngine.mysql;
    if (engStr == 'sqlserver') eng = DbEngine.sqlserver;

    DbEnvironment env = DbEnvironment.development;
    final envStr = json['environment']?.toString();
    if (envStr == 'production') env = DbEnvironment.production;
    if (envStr == 'staging') env = DbEnvironment.staging;

    return DbConnectionConfig(
      id: id,
      name: json['name']?.toString() ?? 'Nova Conexão',
      engine: eng,
      environment: env,
      host: json['host']?.toString() ?? '127.0.0.1',
      port: (json['port'] as num?)?.toInt() ?? eng.defaultPort,
      databaseName: json['databaseName']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      password: pass,
      hasPassword: hasPass || pass.isNotEmpty,
      useSshTunnel: json['useSshTunnel'] == true,
      sshHostId: json['sshHostId']?.toString() ?? '',
      ssl: json['ssl'] == true,
    );
  }

  void saveSecretsToVault(SecureStorageVault vault) {
    if (password.isNotEmpty) {
      vault.setSecret('db_pass_$id', password);
    }
  }

  void clearSecretsFromVault(SecureStorageVault vault) {
    vault.setSecret('db_pass_$id', '');
  }

  DbConnectionConfig copyWith({
    String? name,
    DbEngine? engine,
    DbEnvironment? environment,
    String? host,
    int? port,
    String? databaseName,
    String? username,
    String? password,
    bool? useSshTunnel,
    String? sshHostId,
    bool? ssl,
  }) {
    return DbConnectionConfig(
      id: id,
      name: name ?? this.name,
      engine: engine ?? this.engine,
      environment: environment ?? this.environment,
      host: host ?? this.host,
      port: port ?? this.port,
      databaseName: databaseName ?? this.databaseName,
      username: username ?? this.username,
      password: password ?? this.password,
      hasPassword: (password ?? this.password).isNotEmpty,
      useSshTunnel: useSshTunnel ?? this.useSshTunnel,
      sshHostId: sshHostId ?? this.sshHostId,
      ssl: ssl ?? this.ssl,
    );
  }
}

/// Unified Abstract Database Client
abstract class DatabaseClient {
  Future<void> connect();
  Future<void> disconnect();
  Future<bool> testConnection();
  Future<List<String>> listDatabases();
  Future<List<String>> listSchemas();
  Future<List<String>> listTables({String? schema});
  Future<List<String>> listViews({String? schema});
  Future<List<String>> listFunctions({String? schema});
  Future<List<TableColumnMetadata>> getTableColumns(String table, {String? schema});
  Future<List<TableForeignKey>> getTableForeignKeys(String table, {String? schema});
  Future<List<TableForeignKey>> getReferencingForeignKeys(String table, {String? schema});
  Future<String> getTableDdl(String table, {String? schema});
  Future<DbQueryResult> executeQuery(String sql, {int maxRows = 1000});

  static DatabaseClient create(
    DbConnectionConfig config, {
    String? overrideHost,
    int? overridePort,
  }) {
    final effectiveHost = overrideHost ?? config.host;
    final effectivePort = overridePort ?? config.port;

    switch (config.engine) {
      case DbEngine.postgres:
        return PostgresDatabaseClient(config, host: effectiveHost, port: effectivePort);
      case DbEngine.mysql:
        return MysqlDatabaseClient(config, host: effectiveHost, port: effectivePort);
      case DbEngine.sqlserver:
        return SqlServerDatabaseClient(config, host: effectiveHost, port: effectivePort);
    }
  }
}

/// PostgreSQL Client Implementation
class PostgresDatabaseClient implements DatabaseClient {
  final DbConnectionConfig config;
  final String host;
  final int port;
  pg.Connection? _connection;

  PostgresDatabaseClient(this.config, {required this.host, required this.port});

  @override
  Future<void> connect() async {
    final endpoint = pg.Endpoint(
      host: host,
      port: port,
      database: config.databaseName.isEmpty ? 'postgres' : config.databaseName,
      username: config.username,
      password: config.password,
    );
    _connection = await pg.Connection.open(
      endpoint,
      settings: pg.ConnectionSettings(
        sslMode: config.ssl ? pg.SslMode.require : pg.SslMode.disable,
        connectTimeout: const Duration(seconds: 12),
      ),
    );
  }

  @override
  Future<void> disconnect() async {
    try {
      await _connection?.close();
    } catch (_) {}
    _connection = null;
  }

  @override
  Future<bool> testConnection() async {
    try {
      await connect();
      final res = await _connection?.execute('SELECT 1');
      await disconnect();
      return res != null;
    } catch (e) {
      await disconnect();
      rethrow;
    }
  }

  @override
  Future<List<String>> listDatabases() async {
    if (_connection == null) await connect();
    final res = await _connection!.execute(
      "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname",
    );
    return res.map((r) => r[0].toString()).toList();
  }

  @override
  Future<List<String>> listSchemas() async {
    if (_connection == null) await connect();
    final res = await _connection!.execute(
      "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('information_schema', 'pg_catalog', 'pg_toast') ORDER BY schema_name",
    );
    return res.map((r) => r[0].toString()).toList();
  }

  @override
  Future<List<String>> listTables({String? schema}) async {
    if (_connection == null) await connect();
    final s = schema ?? 'public';
    final res = await _connection!.execute(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = '$s' AND table_type = 'BASE TABLE' ORDER BY table_name",
    );
    return res.map((r) => r[0].toString()).toList();
  }

  @override
  Future<List<String>> listViews({String? schema}) async {
    if (_connection == null) await connect();
    final s = schema ?? 'public';
    final res = await _connection!.execute(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = '$s' AND table_type = 'VIEW' ORDER BY table_name",
    );
    return res.map((r) => r[0].toString()).toList();
  }

  @override
  Future<List<String>> listFunctions({String? schema}) async {
    if (_connection == null) await connect();
    final s = schema ?? 'public';
    final res = await _connection!.execute(
      "SELECT routine_name FROM information_schema.routines WHERE routine_schema = '$s' ORDER BY routine_name",
    );
    return res.map((r) => r[0].toString()).toList();
  }

  @override
  Future<List<TableColumnMetadata>> getTableColumns(String table, {String? schema}) async {
    if (_connection == null) await connect();
    final s = schema ?? 'public';

    // Query columns and PKs
    const sql = '''
      SELECT 
        c.column_name, 
        c.data_type, 
        c.is_nullable, 
        c.column_default,
        (SELECT COUNT(*) FROM information_schema.table_constraints tc
         JOIN information_schema.key_column_usage kcu 
           ON tc.constraint_name = kcu.constraint_name 
           AND tc.table_schema = kcu.table_schema
         WHERE tc.constraint_type = 'PRIMARY KEY' 
           AND tc.table_name = c.table_name 
           AND tc.table_schema = c.table_schema 
           AND kcu.column_name = c.column_name) as is_pk
      FROM information_schema.columns c
      WHERE c.table_name = @t AND c.table_schema = @s
      ORDER BY c.ordinal_position
    ''';

    final res = await _connection!.execute(
      pg.Sql.named(sql),
      parameters: {'t': table, 's': s},
    );

    return res.map((r) {
      final name = r[0]?.toString() ?? '';
      final type = r[1]?.toString() ?? '';
      final nullable = r[2]?.toString().toUpperCase() == 'YES';
      final defVal = r[3]?.toString();
      final isPk = (r[4] as num?)?.toInt() == 1;

      return TableColumnMetadata(
        name: name,
        dataType: type,
        isNullable: nullable,
        isPrimaryKey: isPk,
        defaultValue: defVal,
      );
    }).toList();
  }

  @override
  Future<List<TableForeignKey>> getTableForeignKeys(String table, {String? schema}) async {
    if (_connection == null) await connect();
    final s = schema ?? 'public';
    const sql = '''
      SELECT
        tc.constraint_name,
        kcu.table_schema AS from_schema,
        kcu.table_name AS from_table,
        kcu.column_name AS from_column,
        ccu.table_schema AS to_schema,
        ccu.table_name AS to_table,
        ccu.column_name AS to_column
      FROM information_schema.table_constraints AS tc
      JOIN information_schema.key_column_usage AS kcu
        ON tc.constraint_name = kcu.constraint_name
       AND tc.table_schema = kcu.table_schema
      JOIN information_schema.constraint_column_usage AS ccu
        ON ccu.constraint_name = tc.constraint_name
       AND ccu.table_schema = tc.table_schema
      WHERE tc.constraint_type = 'FOREIGN KEY'
        AND tc.table_schema = @s
        AND tc.table_name = @t
    ''';
    try {
      final res = await _connection!.execute(pg.Sql.named(sql), parameters: {'s': s, 't': table});
      return res.map((r) => TableForeignKey(
        constraintName: r[0]?.toString() ?? '',
        fromSchema: r[1]?.toString() ?? '',
        fromTable: r[2]?.toString() ?? '',
        fromColumn: r[3]?.toString() ?? '',
        toSchema: r[4]?.toString() ?? '',
        toTable: r[5]?.toString() ?? '',
        toColumn: r[6]?.toString() ?? '',
      )).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<TableForeignKey>> getReferencingForeignKeys(String table, {String? schema}) async {
    if (_connection == null) await connect();
    final s = schema ?? 'public';
    const sql = '''
      SELECT
        tc.constraint_name,
        kcu.table_schema AS from_schema,
        kcu.table_name AS from_table,
        kcu.column_name AS from_column,
        ccu.table_schema AS to_schema,
        ccu.table_name AS to_table,
        ccu.column_name AS to_column
      FROM information_schema.table_constraints AS tc
      JOIN information_schema.key_column_usage AS kcu
        ON tc.constraint_name = kcu.constraint_name
       AND tc.table_schema = kcu.table_schema
      JOIN information_schema.constraint_column_usage AS ccu
        ON ccu.constraint_name = tc.constraint_name
       AND ccu.table_schema = tc.table_schema
      WHERE tc.constraint_type = 'FOREIGN KEY'
        AND ccu.table_schema = @s
        AND ccu.table_name = @t
    ''';
    try {
      final res = await _connection!.execute(pg.Sql.named(sql), parameters: {'s': s, 't': table});
      return res.map((r) => TableForeignKey(
        constraintName: r[0]?.toString() ?? '',
        fromSchema: r[1]?.toString() ?? '',
        fromTable: r[2]?.toString() ?? '',
        fromColumn: r[3]?.toString() ?? '',
        toSchema: r[4]?.toString() ?? '',
        toTable: r[5]?.toString() ?? '',
        toColumn: r[6]?.toString() ?? '',
      )).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<String> getTableDdl(String table, {String? schema}) async {
    final cols = await getTableColumns(table, schema: schema);
    final s = schema ?? 'public';
    final buf = StringBuffer();
    buf.writeln('CREATE TABLE $s.$table (');
    final colDefs = <String>[];
    final pks = <String>[];

    for (final c in cols) {
      var line = '  ${c.name} ${c.dataType}';
      if (!c.isNullable) line += ' NOT NULL';
      if (c.defaultValue != null) line += ' DEFAULT ${c.defaultValue}';
      colDefs.add(line);
      if (c.isPrimaryKey) pks.add(c.name);
    }
    if (pks.isNotEmpty) {
      colDefs.add('  PRIMARY KEY (${pks.join(", ")})');
    }
    buf.writeln(colDefs.join(',\n'));
    buf.writeln(');');
    return buf.toString();
  }

  @override
  Future<DbQueryResult> executeQuery(String sql, {int maxRows = 1000}) async {
    if (_connection == null) await connect();
    final sw = Stopwatch()..start();
    try {
      final res = await _connection!.execute(sql);
      sw.stop();

      final cols = res.schema.columns.map((c) => c.columnName ?? '').toList();
      final rows = <List<dynamic>>[];

      for (final r in res) {
        if (rows.length >= maxRows) break;
        rows.add(r.toList());
      }

      return DbQueryResult(
        columns: cols,
        rows: rows,
        executionTimeMs: sw.elapsedMilliseconds,
        affectedRows: res.affectedRows,
      );
    } catch (e) {
      sw.stop();
      return DbQueryResult(
        executionTimeMs: sw.elapsedMilliseconds,
        error: e.toString(),
      );
    }
  }
}

/// MySQL Client Implementation
class MysqlDatabaseClient implements DatabaseClient {
  final DbConnectionConfig config;
  final String host;
  final int port;
  MySQLConnection? _connection;

  MysqlDatabaseClient(this.config, {required this.host, required this.port});

  @override
  Future<void> connect() async {
    _connection = await MySQLConnection.createConnection(
      host: host,
      port: port,
      userName: config.username,
      password: config.password,
      databaseName: config.databaseName.isEmpty ? 'mysql' : config.databaseName,
      secure: config.ssl,
    );
    await _connection!.connect(timeoutMs: 12000);
  }

  @override
  Future<void> disconnect() async {
    try {
      await _connection?.close();
    } catch (_) {}
    _connection = null;
  }

  @override
  Future<bool> testConnection() async {
    try {
      await connect();
      final res = await _connection?.execute('SELECT 1');
      await disconnect();
      return res != null;
    } catch (e) {
      await disconnect();
      rethrow;
    }
  }

  @override
  Future<List<String>> listDatabases() async {
    if (_connection == null) await connect();
    final res = await _connection!.execute("SHOW DATABASES");
    return res.rows.map((r) => r.assoc().values.first?.toString() ?? '').where((s) => s.isNotEmpty).toList();
  }

  @override
  Future<List<String>> listSchemas() async {
    return listDatabases();
  }

  @override
  Future<List<String>> listTables({String? schema}) async {
    if (_connection == null) await connect();
    final db = schema ?? config.databaseName;
    final res = await _connection!.execute(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = '$db' AND table_type = 'BASE TABLE' ORDER BY table_name",
    );
    return res.rows.map((r) => r.assoc().values.first?.toString() ?? '').toList();
  }

  @override
  Future<List<String>> listViews({String? schema}) async {
    if (_connection == null) await connect();
    final db = schema ?? config.databaseName;
    final res = await _connection!.execute(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = '$db' AND table_type = 'VIEW' ORDER BY table_name",
    );
    return res.rows.map((r) => r.assoc().values.first?.toString() ?? '').where((s) => s.isNotEmpty).toList();
  }

  @override
  Future<List<String>> listFunctions({String? schema}) async {
    if (_connection == null) await connect();
    final db = schema ?? config.databaseName;
    final res = await _connection!.execute(
      "SELECT routine_name FROM information_schema.routines WHERE routine_schema = '$db' ORDER BY routine_name",
    );
    return res.rows.map((r) => r.assoc().values.first?.toString() ?? '').where((s) => s.isNotEmpty).toList();
  }

  @override
  Future<List<TableColumnMetadata>> getTableColumns(String table, {String? schema}) async {
    if (_connection == null) await connect();
    final db = schema ?? config.databaseName;
    final res = await _connection!.execute(
      "SELECT column_name, column_type, is_nullable, column_key, column_default FROM information_schema.columns WHERE table_schema = '$db' AND table_name = '$table' ORDER BY ordinal_position",
    );

    return res.rows.map((r) {
      final map = r.assoc();
      final name = map['COLUMN_NAME'] ?? map['column_name'] ?? '';
      final type = map['COLUMN_TYPE'] ?? map['column_type'] ?? '';
      final nullable = (map['IS_NULLABLE'] ?? map['is_nullable'])?.toUpperCase() == 'YES';
      final key = (map['COLUMN_KEY'] ?? map['column_key'])?.toUpperCase() ?? '';
      final defVal = map['COLUMN_DEFAULT'] ?? map['column_default'];

      return TableColumnMetadata(
        name: name,
        dataType: type,
        isNullable: nullable,
        isPrimaryKey: key == 'PRI',
        defaultValue: defVal,
      );
    }).toList();
  }

  @override
  Future<List<TableForeignKey>> getTableForeignKeys(String table, {String? schema}) async {
    if (_connection == null) await connect();
    final db = schema ?? config.databaseName;
    final sql = """
      SELECT 
        kcu.CONSTRAINT_NAME,
        kcu.TABLE_SCHEMA AS from_schema,
        kcu.TABLE_NAME AS from_table,
        kcu.COLUMN_NAME AS from_column,
        kcu.REFERENCED_TABLE_SCHEMA AS to_schema,
        kcu.REFERENCED_TABLE_NAME AS to_table,
        kcu.REFERENCED_COLUMN_NAME AS to_column
      FROM information_schema.KEY_COLUMN_USAGE kcu
      JOIN information_schema.TABLE_CONSTRAINTS tc 
        ON kcu.CONSTRAINT_NAME = tc.CONSTRAINT_NAME 
       AND kcu.TABLE_SCHEMA = tc.TABLE_SCHEMA
      WHERE tc.CONSTRAINT_TYPE = 'FOREIGN KEY'
        AND kcu.TABLE_SCHEMA = '$db'
        AND kcu.TABLE_NAME = '$table'
        AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
    """;
    try {
      final res = await _connection!.execute(sql);
      return res.rows.map((r) {
        final m = r.assoc();
        return TableForeignKey(
          constraintName: m['CONSTRAINT_NAME'] ?? m['constraint_name'] ?? '',
          fromSchema: m['from_schema'] ?? m['FROM_SCHEMA'] ?? '',
          fromTable: m['from_table'] ?? m['FROM_TABLE'] ?? '',
          fromColumn: m['from_column'] ?? m['FROM_COLUMN'] ?? '',
          toSchema: m['to_schema'] ?? m['TO_SCHEMA'] ?? '',
          toTable: m['to_table'] ?? m['TO_TABLE'] ?? '',
          toColumn: m['to_column'] ?? m['TO_COLUMN'] ?? '',
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<TableForeignKey>> getReferencingForeignKeys(String table, {String? schema}) async {
    if (_connection == null) await connect();
    final db = schema ?? config.databaseName;
    final sql = """
      SELECT 
        kcu.CONSTRAINT_NAME,
        kcu.TABLE_SCHEMA AS from_schema,
        kcu.TABLE_NAME AS from_table,
        kcu.COLUMN_NAME AS from_column,
        kcu.REFERENCED_TABLE_SCHEMA AS to_schema,
        kcu.REFERENCED_TABLE_NAME AS to_table,
        kcu.REFERENCED_COLUMN_NAME AS to_column
      FROM information_schema.KEY_COLUMN_USAGE kcu
      JOIN information_schema.TABLE_CONSTRAINTS tc 
        ON kcu.CONSTRAINT_NAME = tc.CONSTRAINT_NAME 
       AND kcu.TABLE_SCHEMA = tc.TABLE_SCHEMA
      WHERE tc.CONSTRAINT_TYPE = 'FOREIGN KEY'
        AND kcu.REFERENCED_TABLE_SCHEMA = '$db'
        AND kcu.REFERENCED_TABLE_NAME = '$table'
    """;
    try {
      final res = await _connection!.execute(sql);
      return res.rows.map((r) {
        final m = r.assoc();
        return TableForeignKey(
          constraintName: m['CONSTRAINT_NAME'] ?? m['constraint_name'] ?? '',
          fromSchema: m['from_schema'] ?? m['FROM_SCHEMA'] ?? '',
          fromTable: m['from_table'] ?? m['FROM_TABLE'] ?? '',
          fromColumn: m['from_column'] ?? m['FROM_COLUMN'] ?? '',
          toSchema: m['to_schema'] ?? m['TO_SCHEMA'] ?? '',
          toTable: m['to_table'] ?? m['TO_TABLE'] ?? '',
          toColumn: m['to_column'] ?? m['TO_COLUMN'] ?? '',
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<String> getTableDdl(String table, {String? schema}) async {
    if (_connection == null) await connect();
    try {
      final db = schema ?? config.databaseName;
      final res = await _connection!.execute('SHOW CREATE TABLE `$db`.`$table`');
      for (final r in res.rows) {
        final vals = r.assoc().values.toList();
        if (vals.length >= 2) return vals[1] ?? '';
      }
    } catch (_) {}
    return 'SHOW CREATE TABLE indisponível.';
  }

  @override
  Future<DbQueryResult> executeQuery(String sql, {int maxRows = 1000}) async {
    if (_connection == null) await connect();
    final sw = Stopwatch()..start();
    try {
      final res = await _connection!.execute(sql);
      sw.stop();

      final cols = res.cols.map((c) => c.name).toList();
      final rows = <List<dynamic>>[];

      for (final r in res.rows) {
        if (rows.length >= maxRows) break;
        final list = <dynamic>[];
        for (final c in res.cols) {
          list.add(r.colByName(c.name));
        }
        rows.add(list);
      }

      return DbQueryResult(
        columns: cols,
        rows: rows,
        executionTimeMs: sw.elapsedMilliseconds,
        affectedRows: res.affectedRows.toInt(),
      );
    } catch (e) {
      sw.stop();
      return DbQueryResult(
        executionTimeMs: sw.elapsedMilliseconds,
        error: e.toString(),
      );
    }
  }
}

/// SQL Server (MSSQL) Client Implementation
class SqlServerDatabaseClient implements DatabaseClient {
  final DbConnectionConfig config;
  final String host;
  final int port;
  MssqlConnection? _connection;

  SqlServerDatabaseClient(this.config, {required this.host, required this.port});

  @override
  Future<void> connect() async {
    _connection = await MssqlConnection.connect(
      host: host,
      port: port,
      user: config.username,
      password: config.password,
      database: config.databaseName.isEmpty ? 'master' : config.databaseName,
      encryptMode: config.ssl ? MssqlEncryptMode.mandatory : MssqlEncryptMode.disabled,
      trustServerCertificate: true,
      timeout: const Duration(seconds: 12),
    );
  }

  @override
  Future<void> disconnect() async {
    try {
      await _connection?.close();
    } catch (_) {}
    _connection = null;
  }

  @override
  Future<bool> testConnection() async {
    try {
      await connect();
      final res = await _connection?.query('SELECT 1 as ok');
      await disconnect();
      return res != null;
    } catch (e) {
      await disconnect();
      rethrow;
    }
  }

  @override
  Future<List<String>> listDatabases() async {
    if (_connection == null) await connect();
    final res = await _connection!.query("SELECT name FROM sys.databases WHERE state = 0 ORDER BY name");
    return res.rows.map((r) => r['name']?.toString() ?? '').where((s) => s.isNotEmpty).toList();
  }

  @override
  Future<List<String>> listSchemas() async {
    if (_connection == null) await connect();
    final res = await _connection!.query(
      "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('guest', 'INFORMATION_SCHEMA', 'sys', 'db_owner', 'db_accessadmin', 'db_securityadmin', 'db_ddladmin', 'db_backupoperator', 'db_datareader', 'db_datawriter', 'db_denydatareader', 'db_denydatawriter') ORDER BY schema_name",
    );
    return res.rows.map((r) => r['schema_name']?.toString() ?? '').toList();
  }

  @override
  Future<List<String>> listTables({String? schema}) async {
    if (_connection == null) await connect();
    final s = schema ?? 'dbo';
    final res = await _connection!.query(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = '$s' AND table_type = 'BASE TABLE' ORDER BY table_name",
    );
    return res.rows.map((r) => r['table_name']?.toString() ?? '').toList();
  }

  @override
  Future<List<String>> listViews({String? schema}) async {
    if (_connection == null) await connect();
    final s = schema ?? 'dbo';
    final res = await _connection!.query(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = '$s' AND table_type = 'VIEW' ORDER BY table_name",
    );
    return res.rows.map((r) => r['table_name']?.toString() ?? '').toList();
  }

  @override
  Future<List<String>> listFunctions({String? schema}) async {
    if (_connection == null) await connect();
    final s = schema ?? 'dbo';
    final res = await _connection!.query(
      "SELECT routine_name FROM information_schema.routines WHERE routine_schema = '$s' ORDER BY routine_name",
    );
    return res.rows.map((r) => r['routine_name']?.toString() ?? '').toList();
  }

  @override
  Future<List<TableColumnMetadata>> getTableColumns(String table, {String? schema}) async {
    if (_connection == null) await connect();
    final s = schema ?? 'dbo';

    const sql = '''
      SELECT 
        c.COLUMN_NAME, 
        c.DATA_TYPE, 
        c.IS_NULLABLE, 
        c.COLUMN_DEFAULT,
        (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
         JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu 
           ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME 
           AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
         WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY' 
           AND tc.TABLE_NAME = c.TABLE_NAME 
           AND tc.TABLE_SCHEMA = c.TABLE_SCHEMA 
           AND kcu.COLUMN_NAME = c.COLUMN_NAME) as IS_PK
      FROM INFORMATION_SCHEMA.COLUMNS c
      WHERE c.TABLE_NAME = @p0 AND c.TABLE_SCHEMA = @p1
      ORDER BY c.ORDINAL_POSITION
    ''';

    // Query with replace for safety
    final finalSql = sql.replaceAll('@p0', "'${table.replaceAll("'", "''")}'").replaceAll('@p1', "'${s.replaceAll("'", "''")}'");
    final res = await _connection!.query(finalSql);

    return res.rows.map((r) {
      final name = r['COLUMN_NAME']?.toString() ?? '';
      final type = r['DATA_TYPE']?.toString() ?? '';
      final nullable = r['IS_NULLABLE']?.toString().toUpperCase() == 'YES';
      final defVal = r['COLUMN_DEFAULT']?.toString();
      final isPk = (r['IS_PK'] as num?)?.toInt() == 1;

      return TableColumnMetadata(
        name: name,
        dataType: type,
        isNullable: nullable,
        isPrimaryKey: isPk,
        defaultValue: defVal,
      );
    }).toList();
  }

  @override
  Future<List<TableForeignKey>> getTableForeignKeys(String table, {String? schema}) async {
    if (_connection == null) await connect();
    final s = schema ?? 'dbo';
    final sql = """
      SELECT 
        fk.name AS constraint_name,
        s1.name AS from_schema,
        t1.name AS from_table,
        c1.name AS from_column,
        s2.name AS to_schema,
        t2.name AS to_table,
        c2.name AS to_column
      FROM sys.foreign_keys fk
      INNER JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
      INNER JOIN sys.tables t1 ON fkc.parent_object_id = t1.object_id
      INNER JOIN sys.schemas s1 ON t1.schema_id = s1.schema_id
      INNER JOIN sys.columns c1 ON fkc.parent_object_id = c1.object_id AND fkc.parent_column_id = c1.column_id
      INNER JOIN sys.tables t2 ON fkc.referenced_object_id = t2.object_id
      INNER JOIN sys.schemas s2 ON t2.schema_id = s2.schema_id
      INNER JOIN sys.columns c2 ON fkc.referenced_object_id = c2.object_id AND fkc.referenced_column_id = c2.column_id
      WHERE s1.name = '$s' AND t1.name = '$table'
    """;
    try {
      final res = await _connection!.query(sql);
      return res.rows.map((r) => TableForeignKey(
        constraintName: r['constraint_name']?.toString() ?? '',
        fromSchema: r['from_schema']?.toString() ?? '',
        fromTable: r['from_table']?.toString() ?? '',
        fromColumn: r['from_column']?.toString() ?? '',
        toSchema: r['to_schema']?.toString() ?? '',
        toTable: r['to_table']?.toString() ?? '',
        toColumn: r['to_column']?.toString() ?? '',
      )).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<TableForeignKey>> getReferencingForeignKeys(String table, {String? schema}) async {
    if (_connection == null) await connect();
    final s = schema ?? 'dbo';
    final sql = """
      SELECT 
        fk.name AS constraint_name,
        s1.name AS from_schema,
        t1.name AS from_table,
        c1.name AS from_column,
        s2.name AS to_schema,
        t2.name AS to_table,
        c2.name AS to_column
      FROM sys.foreign_keys fk
      INNER JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
      INNER JOIN sys.tables t1 ON fkc.parent_object_id = t1.object_id
      INNER JOIN sys.schemas s1 ON t1.schema_id = s1.schema_id
      INNER JOIN sys.columns c1 ON fkc.parent_object_id = c1.object_id AND fkc.parent_column_id = c1.column_id
      INNER JOIN sys.tables t2 ON fkc.referenced_object_id = t2.object_id
      INNER JOIN sys.schemas s2 ON t2.schema_id = s2.schema_id
      INNER JOIN sys.columns c2 ON fkc.referenced_object_id = c2.object_id AND fkc.referenced_column_id = c2.column_id
      WHERE s2.name = '$s' AND t2.name = '$table'
    """;
    try {
      final res = await _connection!.query(sql);
      return res.rows.map((r) => TableForeignKey(
        constraintName: r['constraint_name']?.toString() ?? '',
        fromSchema: r['from_schema']?.toString() ?? '',
        fromTable: r['from_table']?.toString() ?? '',
        fromColumn: r['from_column']?.toString() ?? '',
        toSchema: r['to_schema']?.toString() ?? '',
        toTable: r['to_table']?.toString() ?? '',
        toColumn: r['to_column']?.toString() ?? '',
      )).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<String> getTableDdl(String table, {String? schema}) async {
    final cols = await getTableColumns(table, schema: schema);
    final s = schema ?? 'dbo';
    final buf = StringBuffer();
    buf.writeln('CREATE TABLE [$s].[$table] (');
    final colDefs = <String>[];
    final pks = <String>[];

    for (final c in cols) {
      var line = '  [${c.name}] ${c.dataType.toUpperCase()}';
      if (!c.isNullable) line += ' NOT NULL';
      if (c.defaultValue != null) line += ' DEFAULT ${c.defaultValue}';
      colDefs.add(line);
      if (c.isPrimaryKey) pks.add('[${c.name}]');
    }
    if (pks.isNotEmpty) {
      colDefs.add('  CONSTRAINT [PK_$table] PRIMARY KEY (${pks.join(", ")})');
    }
    buf.writeln(colDefs.join(',\n'));
    buf.writeln(');');
    return buf.toString();
  }

  @override
  Future<DbQueryResult> executeQuery(String sql, {int maxRows = 1000}) async {
    if (_connection == null) await connect();
    final sw = Stopwatch()..start();
    try {
      final res = await _connection!.query(sql);
      sw.stop();

      final cols = res.columns.map((c) => c.name).toList();
      final rows = <List<dynamic>>[];

      for (final r in res.rows) {
        if (rows.length >= maxRows) break;
        rows.add(r.values);
      }

      return DbQueryResult(
        columns: cols,
        rows: rows,
        executionTimeMs: sw.elapsedMilliseconds,
        affectedRows: res.rowsAffected,
      );
    } catch (e) {
      sw.stop();
      return DbQueryResult(
        executionTimeMs: sw.elapsedMilliseconds,
        error: e.toString(),
      );
    }
  }
}
