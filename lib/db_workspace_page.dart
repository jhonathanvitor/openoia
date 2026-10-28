import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'db_models.dart';
import 'db_tunnel_manager.dart';
import 'secure_storage.dart';
import 'ssh_models.dart';

/// Workspace Tab representation
abstract class DbWorkspaceTab {
  final String id;
  String title;
  final IconData icon;

  DbWorkspaceTab({required this.id, required this.title, required this.icon});
}

class SqlSuggestion {
  final String label;
  final String insertText;
  final String category;
  final IconData icon;
  final Color color;

  const SqlSuggestion({
    required this.label,
    required this.insertText,
    required this.category,
    required this.icon,
    required this.color,
  });
}

class QueryTabItem extends DbWorkspaceTab {
  final TextEditingController sqlController;
  final ScrollController verticalScroll = ScrollController();
  final ScrollController horizontalScroll = ScrollController();
  List<DbQueryResult> results = [];
  int selectedResultIndex = 0;
  bool isRunning = false;
  int pageIndex = 0;
  int pageSize = 50;
  String tableSearchFilter = '';
  String? filePath;
  bool isDirty = false;
  String selectedSchema;
  List<SqlSuggestion> currentSuggestions = [];

  DbQueryResult? get currentResult =>
      (results.isNotEmpty && selectedResultIndex < results.length) ? results[selectedResultIndex] : null;
  DbQueryResult? get result => currentResult;

  QueryTabItem({
    required super.id,
    required super.title,
    String initialSql = '',
    this.filePath,
    this.selectedSchema = '',
  })  : sqlController = TextEditingController(text: initialSql),
        super(icon: Icons.code_rounded);
}

class _SaveSqlIntent extends Intent {
  const _SaveSqlIntent();
}

class TableTabItem extends DbWorkspaceTab {
  final String schema;
  final String tableName;
  final ScrollController verticalScroll = ScrollController();
  final ScrollController horizontalScroll = ScrollController();
  int subTabIndex; // 0: Dados, 1: Estrutura, 2: FKs, 3: DDL
  DbQueryResult? dataResult;
  List<TableColumnMetadata>? columns;
  List<TableForeignKey> foreignKeys = [];
  List<TableForeignKey> referencingKeys = [];
  String? ddl;
  bool isLoading;
  int pageIndex;
  int pageSize;
  String searchFilter;

  TableTabItem({
    required super.id,
    required this.schema,
    required this.tableName,
  })  : subTabIndex = 0,
        isLoading = false,
        pageIndex = 0,
        pageSize = 50,
        searchFilter = '',
        super(title: tableName, icon: Icons.table_chart_rounded);
}

class DbWorkspacePage extends StatefulWidget {
  final bool isDark;
  final Directory configDir;

  const DbWorkspacePage({
    super.key,
    required this.isDark,
    required this.configDir,
  });

  @override
  State<DbWorkspacePage> createState() => _DbWorkspacePageState();
}

class _DbWorkspacePageState extends State<DbWorkspacePage> {
  late final SecureStorageVault _vault;
  late final File _connectionsFile;
  late final SshHelperManager _sshHelper;
  late final DbTunnelManager _tunnelManager;

  final List<DbConnectionConfig> _connections = [];
  final List<SshHostConfig> _sshHosts = [];

  DbConnectionConfig? _activeConnection;
  DatabaseClient? _activeClient;
  Process? _activeTunnelProcess;
  bool _isConnecting = false;

  // Metadata tree (DBeaver style)
  List<String> _schemas = [];
  String _selectedSchema = '';
  final Set<String> _expandedDatabases = {};
  final Set<String> _expandedFolders = {}; // Keys: "$schema:tables", "$schema:views", "$schema:functions"
  final Map<String, List<String>> _databaseTables = {};
  final Map<String, List<String>> _databaseViews = {};
  final Map<String, List<String>> _databaseFunctions = {};
  final Map<String, List<TableColumnMetadata>> _tableColumnsCache = {};
  final Set<String> _expandedTables = {}; // Keys: "$schema:$table"
  String _treeSearchQuery = '';

  // Workspace Tabs
  final List<DbWorkspaceTab> _tabs = [];
  int _activeTabIndex = 0;
  int _queryCounter = 1;

  @override
  void initState() {
    super.initState();
    _vault = SecureStorageVault(widget.configDir);
    _connectionsFile = File('${widget.configDir.path}/db_connections.json');
    _sshHelper = SshHelperManager(widget.configDir);
    _tunnelManager = DbTunnelManager(_sshHelper);

    _loadSshHosts();
    _loadConnections();
  }

  @override
  void dispose() {
    for (final tab in _tabs) {
      if (tab is QueryTabItem) {
        tab.sqlController.dispose();
        tab.verticalScroll.dispose();
        tab.horizontalScroll.dispose();
      } else if (tab is TableTabItem) {
        tab.verticalScroll.dispose();
        tab.horizontalScroll.dispose();
      }
    }
    _disconnectActive();
    _tunnelManager.closeAll();
    super.dispose();
  }

  void _loadSshHosts() {
    final file = File('${widget.configDir.path}/ssh_hosts.json');
    if (file.existsSync()) {
      try {
        final list = _vault.readEncryptedJson(file);
        if (list is List) {
          _sshHosts.clear();
          for (final item in list) {
            if (item is Map<String, dynamic>) {
              _sshHosts.add(SshHostConfig.fromJson(item, vault: _vault));
            }
          }
        }
      } catch (_) {}
    }
  }

  void _loadConnections() {
    if (_connectionsFile.existsSync()) {
      try {
        final list = _vault.readEncryptedJson(_connectionsFile);
        if (list is List) {
          _connections.clear();
          for (final item in list) {
            if (item is Map<String, dynamic>) {
              _connections.add(DbConnectionConfig.fromJson(item, vault: _vault));
            }
          }
          setState(() {});
        }
      } catch (_) {}
    }
  }

  void _saveConnections() {
    for (final c in _connections) {
      c.saveSecretsToVault(_vault);
    }
    final list = _connections.map((c) => c.toJson()).toList();
    _vault.writeEncryptedJson(_connectionsFile, list);
  }

  void _addNewQueryTab({String initialSql = '', String? schema, String? filePath}) {
    final title = filePath != null ? filePath.split('/').last : 'Query $_queryCounter.sql';
    if (filePath == null) _queryCounter++;
    final tab = QueryTabItem(
      id: 'query_${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      initialSql: initialSql.isEmpty ? '-- Escreva sua consulta SQL e pressione Ctrl+Enter ou clique em Executar\n' : initialSql,
      filePath: filePath,
      selectedSchema: schema ?? _selectedSchema,
    );
    setState(() {
      _tabs.add(tab);
      _activeTabIndex = _tabs.length - 1;
    });
  }

  void _closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs[index];
    if (tab is QueryTabItem) {
      tab.sqlController.dispose();
      tab.verticalScroll.dispose();
      tab.horizontalScroll.dispose();
    } else if (tab is TableTabItem) {
      tab.verticalScroll.dispose();
      tab.horizontalScroll.dispose();
    }
    setState(() {
      _tabs.removeAt(index);
      if (_tabs.isEmpty) {
        _activeTabIndex = 0;
      } else if (_activeTabIndex >= _tabs.length) {
        _activeTabIndex = _tabs.length - 1;
      }
    });
  }

  Future<void> _connectTo(DbConnectionConfig conn) async {
    if (_activeConnection?.id == conn.id && _activeClient != null) return;
    await _disconnectActive();

    setState(() {
      _isConnecting = true;
      _activeConnection = conn;
    });

    try {
      String effectiveHost = conn.host;
      int effectivePort = conn.port;

      if (conn.useSshTunnel && conn.sshHostId.isNotEmpty) {
        final sshHost = _sshHosts.firstWhere(
          (h) => h.id == conn.sshHostId,
          orElse: () => throw Exception('Servidor SSH associado ao túnel não foi encontrado.'),
        );

        final (localPort, proc) = await _tunnelManager.openTunnel(
          sshHost: sshHost,
          remoteDbHost: conn.host,
          remoteDbPort: conn.port,
        );
        _activeTunnelProcess = proc;
        effectiveHost = '127.0.0.1';
        effectivePort = localPort;
      }

      final client = DatabaseClient.create(
        conn,
        overrideHost: effectiveHost,
        overridePort: effectivePort,
      );

      await client.connect();
      _activeClient = client;

      // Load databases / schemas (DBeaver style)
      _schemas = await client.listSchemas();
      if (_schemas.isEmpty) {
        _schemas = [conn.databaseName.isNotEmpty ? conn.databaseName : 'public'];
      }
      _selectedSchema = conn.databaseName.isNotEmpty && _schemas.contains(conn.databaseName)
          ? conn.databaseName
          : (_schemas.contains('public') ? 'public' : _schemas.first);

      _expandedDatabases.clear();
      _expandedFolders.clear();
      _databaseTables.clear();
      _databaseViews.clear();
      _databaseFunctions.clear();
      _tableColumnsCache.clear();
      _expandedTables.clear();

      _expandedDatabases.add(_selectedSchema);
      _expandedFolders.add('$_selectedSchema:tables');
      await _loadSchemaContent(_selectedSchema);

      if (mounted) {
        setState(() => _isConnecting = false);
      }
    } catch (e) {
      await _disconnectActive();
      if (mounted) {
        setState(() => _isConnecting = false);
        final errStr = e.toString();
        String msg;
        if (e is SocketException || errStr.contains('SocketException') || errStr.contains('errno = 111')) {
          msg = 'Não foi possível conectar em ${conn.host}:${conn.port} (Conexão recusada).\n\n'
                '• Verifique se o serviço do banco de dados está ativo.\n'
                '• Confirme se a porta ${conn.port} está correta (no Docker, veja a porta mapeada no host).\n'
                '• Se estiver usando banco local sem SSH, desative a opção "Túnel SSH Integrado".';
        } else {
          msg = errStr;
        }
        _showErrorDialog('Falha na Conexão', msg);
      }
    }
  }

  Future<void> _disconnectActive() async {
    try {
      await _activeClient?.disconnect();
    } catch (_) {}
    _activeClient = null;

    if (_activeTunnelProcess != null) {
      _tunnelManager.closeTunnel(_activeTunnelProcess);
      _activeTunnelProcess = null;
    }

    if (mounted) {
      setState(() {
        _activeConnection = null;
        _schemas.clear();
        _expandedDatabases.clear();
        _expandedFolders.clear();
        _databaseTables.clear();
        _databaseViews.clear();
        _databaseFunctions.clear();
        _tableColumnsCache.clear();
        _expandedTables.clear();
      });
    }
  }

  Future<void> _loadSchemaContent(String schema) async {
    if (_activeClient == null) return;
    try {
      final tables = await _activeClient!.listTables(schema: schema);
      final views = await _activeClient!.listViews(schema: schema);
      final functions = await _activeClient!.listFunctions(schema: schema);
      if (mounted) {
        setState(() {
          _databaseTables[schema] = tables;
          _databaseViews[schema] = views;
          _databaseFunctions[schema] = functions;
        });
      }
    } catch (_) {}
  }

  Future<void> _refreshTree() async {
    if (_activeClient == null) return;
    try {
      _schemas = await _activeClient!.listSchemas();
      if (_schemas.isEmpty) {
        _schemas = [_activeConnection?.databaseName.isNotEmpty == true ? _activeConnection!.databaseName : 'public'];
      }
      _databaseTables.clear();
      _databaseViews.clear();
      _databaseFunctions.clear();
      _tableColumnsCache.clear();
      if (_selectedSchema.isEmpty || !_schemas.contains(_selectedSchema)) {
        _selectedSchema = _schemas.first;
      }
      _expandedDatabases.add(_selectedSchema);
      _expandedFolders.add('$_selectedSchema:tables');
      await _loadSchemaContent(_selectedSchema);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _openTableTab(String table, {String? schema}) async {
    final sch = schema ?? _selectedSchema;
    final existingIdx = _tabs.indexWhere(
      (t) => t is TableTabItem && t.tableName == table && t.schema == sch,
    );
    if (existingIdx >= 0) {
      setState(() => _activeTabIndex = existingIdx);
      return;
    }

    final tab = TableTabItem(
      id: 'table_${sch}_$table',
      schema: sch,
      tableName: table,
    );

    setState(() {
      _tabs.add(tab);
      _activeTabIndex = _tabs.length - 1;
    });

    await _loadTableData(tab);
  }

  String _formatTableName(String schema, String table) {
    if (_activeConnection?.engine == DbEngine.mysql) {
      return '`$schema`.`$table`';
    } else if (_activeConnection?.engine == DbEngine.sqlserver) {
      return '[$schema].[$table]';
    }
    return '"$schema"."$table"';
  }

  Future<void> _loadTableData(TableTabItem tab, {int limit = 1000}) async {
    if (_activeClient == null) return;
    setState(() => tab.isLoading = true);

    try {
      final query = _activeConnection?.engine == DbEngine.sqlserver
          ? 'SELECT TOP $limit * FROM ${_formatTableName(tab.schema, tab.tableName)};'
          : 'SELECT * FROM ${_formatTableName(tab.schema, tab.tableName)} LIMIT $limit;';
      final res = await _activeClient!.executeQuery(query, maxRows: limit);
      final cols = await _activeClient!.getTableColumns(tab.tableName, schema: tab.schema);
      final fks = await _activeClient!.getTableForeignKeys(tab.tableName, schema: tab.schema);
      final refFks = await _activeClient!.getReferencingForeignKeys(tab.tableName, schema: tab.schema);
      final ddl = await _activeClient!.getTableDdl(tab.tableName, schema: tab.schema);

      if (mounted) {
        setState(() {
          tab.dataResult = res;
          tab.columns = cols;
          tab.foreignKeys = fks;
          tab.referencingKeys = refFks;
          tab.ddl = ddl;
          tab.isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          tab.dataResult = DbQueryResult(error: e.toString());
          tab.isLoading = false;
        });
      }
    }
  }

  void _navigateForeignKey(String toSchema, String toTable, String toColumn, dynamic value) {
    if (value == null) return;
    final valStr = value.toString().replaceAll("'", "''");
    final target = _formatTableName(toSchema, toTable);
    final sql = "-- Navegação por Chave Estrangeira: $toTable ($toColumn = $valStr)\nSELECT * FROM $target WHERE $toColumn = '$valStr';\n";
    _addNewQueryTab(initialSql: sql, schema: toSchema);
    final newTab = _tabs.last as QueryTabItem;
    _executeQuery(newTab);
  }

  void _navigateReferencingTable(String fromSchema, String fromTable, String fromColumn, dynamic value) {
    if (value == null) return;
    final valStr = value.toString().replaceAll("'", "''");
    final target = _formatTableName(fromSchema, fromTable);
    final sql = "-- Registros Dependentes: $fromTable ($fromColumn = $valStr)\nSELECT * FROM $target WHERE $fromColumn = '$valStr';\n";
    _addNewQueryTab(initialSql: sql, schema: fromSchema);
    final newTab = _tabs.last as QueryTabItem;
    _executeQuery(newTab);
  }

  void _selectTop1000(String schema, String table) {
    final formattedTable = _formatTableName(schema, table);
    final sql = _activeConnection?.engine == DbEngine.sqlserver
        ? 'SELECT TOP 1000 * FROM $formattedTable;\n'
        : 'SELECT * FROM $formattedTable LIMIT 1000;\n';
    _addNewQueryTab(initialSql: sql);
    final newTab = _tabs.last as QueryTabItem;
    _executeQuery(newTab);
  }

  void _countRecords(String schema, String table) {
    final formattedTable = _formatTableName(schema, table);
    final sql = 'SELECT COUNT(*) AS total_registros FROM $formattedTable;\n';
    _addNewQueryTab(initialSql: sql);
    final newTab = _tabs.last as QueryTabItem;
    _executeQuery(newTab);
  }

  void _showTableContextMenu(BuildContext context, Offset position, String schema, String table, {bool isView = false}) {
    final textStyle = TextStyle(fontSize: 12.5, color: widget.isDark ? Colors.white : Colors.black87);
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx + 1, position.dy + 1),
      items: [
        PopupMenuItem(
          value: 'select_1000',
          child: Row(
            children: [
              const Icon(Icons.table_rows_rounded, size: 16, color: Color(0xFF10B981)),
              const SizedBox(width: 8),
              Text('Selecionar os primeiros 1.000 dados', style: textStyle),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'count',
          child: Row(
            children: [
              const Icon(Icons.calculate_outlined, size: 16, color: Color(0xFF38BDF8)),
              const SizedBox(width: 8),
              Text('Contar Registros (COUNT)', style: textStyle),
            ],
          ),
        ),
        if (!isView)
          PopupMenuItem(
            value: 'open_tab',
            child: Row(
              children: [
                const Icon(Icons.schema_rounded, size: 16, color: Color(0xFF818CF8)),
                const SizedBox(width: 8),
                Text('Abrir Tabela & Estrutura', style: textStyle),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'new_query',
          child: Row(
            children: [
              const Icon(Icons.edit_note_rounded, size: 16, color: Color(0xFFF59E0B)),
              const SizedBox(width: 8),
              Text('Nova Consulta SQL nesta ${isView ? 'view' : 'tabela'}', style: textStyle),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'copy_name',
          child: Row(
            children: [
              const Icon(Icons.copy_rounded, size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Text('Copiar Nome', style: textStyle),
            ],
          ),
        ),
      ],
    ).then((val) {
      if (val == 'select_1000') {
        _selectTop1000(schema, table);
      } else if (val == 'count') {
        _countRecords(schema, table);
      } else if (val == 'open_tab') {
        _openTableTab(table, schema: schema);
      } else if (val == 'new_query') {
        _addNewQueryTab(initialSql: 'SELECT * FROM ${_formatTableName(schema, table)} WHERE 1=1;\n');
      } else if (val == 'copy_name') {
        Clipboard.setData(ClipboardData(text: table));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Nome "$table" copiado!')),
          );
        }
      }
    });
  }

  void _showDatabaseContextMenu(BuildContext context, Offset position, String schema) {
    final textStyle = TextStyle(fontSize: 12.5, color: widget.isDark ? Colors.white : Colors.black87);
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx + 1, position.dy + 1),
      items: [
        PopupMenuItem(
          value: 'new_query',
          child: Row(
            children: [
              const Icon(Icons.post_add_rounded, size: 16, color: Color(0xFF10B981)),
              const SizedBox(width: 8),
              Text('Nova Consulta SQL em "$schema"', style: textStyle),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'refresh',
          child: Row(
            children: [
              const Icon(Icons.refresh_rounded, size: 16, color: Color(0xFF38BDF8)),
              const SizedBox(width: 8),
              Text('Recarregar Banco', style: textStyle),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'copy_name',
          child: Row(
            children: [
              const Icon(Icons.copy_rounded, size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Text('Copiar Nome do Banco', style: textStyle),
            ],
          ),
        ),
      ],
    ).then((val) {
      if (val == 'new_query') {
        final initialSql = _activeConnection?.engine == DbEngine.mysql
            ? 'USE `$schema`;\n\n'
            : (_activeConnection?.engine == DbEngine.sqlserver ? 'USE [$schema];\n\n' : '-- Esquema: $schema\n\n');
        _addNewQueryTab(initialSql: initialSql, schema: schema);
      } else if (val == 'refresh') {
        _loadSchemaContent(schema);
      } else if (val == 'copy_name') {
        Clipboard.setData(ClipboardData(text: schema));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Nome "$schema" copiado!')),
          );
        }
      }
    });
  }

  void _showQueryTabContextMenu(BuildContext context, Offset position, QueryTabItem tab, int index) {
    final textStyle = TextStyle(fontSize: 12.5, color: widget.isDark ? Colors.white : Colors.black87);
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx + 1, position.dy + 1),
      items: [
        PopupMenuItem(
          value: 'save',
          child: Row(
            children: [
              const Icon(Icons.save_rounded, size: 16, color: Color(0xFF10B981)),
              const SizedBox(width: 8),
              Text(tab.filePath != null ? 'Salvar (${tab.title})' : 'Salvar Consulta (.sql)', style: textStyle),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'save_as',
          child: Row(
            children: [
              const Icon(Icons.save_as_rounded, size: 16, color: Color(0xFF38BDF8)),
              const SizedBox(width: 8),
              Text('Salvar Como...', style: textStyle),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'close',
          child: Row(
            children: [
              const Icon(Icons.close_rounded, size: 16, color: Color(0xFFEF4444)),
              const SizedBox(width: 8),
              Text('Fechar Aba', style: textStyle),
            ],
          ),
        ),
      ],
    ).then((val) {
      if (val == 'save') {
        _saveQueryTab(tab);
      } else if (val == 'save_as') {
        _saveQueryTabAs(tab);
      } else if (val == 'close') {
        _closeTab(index);
      }
    });
  }

  Future<void> _saveQueryTab(QueryTabItem tab) async {
    if (tab.filePath != null) {
      try {
        final f = File(tab.filePath!);
        await f.writeAsString(tab.sqlController.text);
        setState(() {
          tab.isDirty = false;
          tab.title = tab.filePath!.split('/').last;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Consulta salva em ${tab.filePath}!')),
          );
        }
        return;
      } catch (_) {}
    }
    await _saveQueryTabAs(tab);
  }

  Future<void> _saveQueryTabAs(QueryTabItem tab) async {
    try {
      final defaultName = tab.title.replaceAll('*', '').trim().isEmpty ? 'consulta.sql' : tab.title.replaceAll('*', '').trim();
      final res = await Process.run('zenity', [
        '--file-selection',
        '--save',
        '--confirm-overwrite',
        '--title=Salvar Consulta SQL',
        '--filename=$defaultName',
        '--file-filter=Arquivos SQL (*.sql) | *.sql',
      ]);
      if (res.exitCode == 0) {
        String chosen = res.stdout.toString().trim();
        if (chosen.isNotEmpty) {
          if (!chosen.endsWith('.sql')) chosen += '.sql';
          final f = File(chosen);
          await f.writeAsString(tab.sqlController.text);
          setState(() {
            tab.filePath = chosen;
            tab.isDirty = false;
            tab.title = chosen.split('/').last;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Consulta salva em $chosen!')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) _showErrorDialog('Erro ao Salvar', e.toString());
    }
  }

  Future<void> _openQueryFromFile() async {
    try {
      final res = await Process.run('zenity', [
        '--file-selection',
        '--title=Abrir Consulta SQL',
        '--file-filter=Arquivos SQL (*.sql) | *.sql',
      ]);
      if (res.exitCode == 0) {
        final chosen = res.stdout.toString().trim();
        if (chosen.isNotEmpty) {
          final f = File(chosen);
          if (f.existsSync()) {
            final content = await f.readAsString();
            _addNewQueryTab(initialSql: content, filePath: chosen);
          }
        }
      }
    } catch (e) {
      if (mounted) _showErrorDialog('Erro ao Abrir', e.toString());
    }
  }

  List<String> _splitSqlStatements(String sql) => splitSqlStatements(sql);

  void _onSqlTextChanged(QueryTabItem tab) {
    if (!tab.isDirty) {
      setState(() {
        tab.isDirty = true;
        if (!tab.title.endsWith('*')) tab.title = '${tab.title}*';
      });
    }

    final text = tab.sqlController.text;
    final sel = tab.sqlController.selection;
    if (sel.baseOffset <= 0 || sel.baseOffset > text.length) {
      if (tab.currentSuggestions.isNotEmpty) setState(() => tab.currentSuggestions = []);
      return;
    }

    final beforeCursor = text.substring(0, sel.baseOffset);
    final match = RegExp(r'[a-zA-Z0-9_]+$').firstMatch(beforeCursor);
    if (match == null || match.group(0) == null || match.group(0)!.isEmpty) {
      if (tab.currentSuggestions.isNotEmpty) setState(() => tab.currentSuggestions = []);
      return;
    }

    final token = match.group(0)!.toLowerCase();
    final suggestions = <SqlSuggestion>[];

    final sch = tab.selectedSchema.isNotEmpty ? tab.selectedSchema : _selectedSchema;
    final tables = _databaseTables[sch] ?? [];
    for (final t in tables) {
      if (t.toLowerCase().startsWith(token) || (token.length >= 2 && t.toLowerCase().contains(token))) {
        suggestions.add(SqlSuggestion(
          label: t,
          insertText: _activeConnection?.engine == DbEngine.mysql ? '`$t`' : t,
          category: 'Tabela',
          icon: Icons.table_chart_rounded,
          color: const Color(0xFF38BDF8),
        ));
      }
    }

    final views = _databaseViews[sch] ?? [];
    for (final v in views) {
      if (v.toLowerCase().startsWith(token) || (token.length >= 2 && v.toLowerCase().contains(token))) {
        suggestions.add(SqlSuggestion(
          label: v,
          insertText: v,
          category: 'View',
          icon: Icons.visibility_rounded,
          color: const Color(0xFF818CF8),
        ));
      }
    }

    for (final entry in _tableColumnsCache.entries) {
      for (final col in entry.value) {
        if (col.name.toLowerCase().startsWith(token) && !suggestions.any((s) => s.label == col.name)) {
          suggestions.add(SqlSuggestion(
            label: col.name,
            insertText: col.name,
            category: 'Coluna',
            icon: col.isPrimaryKey ? Icons.key_rounded : Icons.view_column_rounded,
            color: col.isPrimaryKey ? const Color(0xFFF59E0B) : const Color(0xFF10B981),
          ));
        }
      }
    }

    const keywords = [
      'SELECT', 'FROM', 'WHERE', 'INSERT INTO', 'UPDATE', 'DELETE FROM',
      'JOIN', 'LEFT JOIN', 'INNER JOIN', 'RIGHT JOIN', 'ON',
      'ORDER BY', 'GROUP BY', 'HAVING', 'LIMIT', 'OFFSET',
      'DISTINCT', 'AS', 'AND', 'OR', 'NOT', 'IN', 'IS NULL', 'IS NOT NULL',
      'LIKE', 'BETWEEN', 'COUNT(*)', 'SUM', 'AVG', 'MIN', 'MAX',
      'CREATE TABLE', 'DROP TABLE', 'ALTER TABLE', 'TRUNCATE'
    ];
    for (final kw in keywords) {
      if (kw.toLowerCase().startsWith(token)) {
        suggestions.add(SqlSuggestion(
          label: kw,
          insertText: kw,
          category: 'SQL',
          icon: Icons.code_rounded,
          color: const Color(0xFFF59E0B),
        ));
      }
    }

    setState(() {
      tab.currentSuggestions = suggestions.take(8).toList();
    });
  }

  void _applySuggestion(QueryTabItem tab, SqlSuggestion suggestion) {
    final text = tab.sqlController.text;
    final sel = tab.sqlController.selection;
    if (sel.baseOffset <= 0) return;

    final beforeCursor = text.substring(0, sel.baseOffset);
    final afterCursor = text.substring(sel.baseOffset);
    final match = RegExp(r'[a-zA-Z0-9_]+$').firstMatch(beforeCursor);
    if (match == null) return;

    final tokenStart = match.start;
    final newText = '${text.substring(0, tokenStart)}${suggestion.insertText} $afterCursor';
    final newCursor = tokenStart + suggestion.insertText.length + 1;

    tab.sqlController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );

    setState(() {
      tab.currentSuggestions = [];
    });
  }

  Future<void> _executeQuery(QueryTabItem tab) async {
    if (_activeClient == null) {
      _showErrorDialog('Sem Conexão', 'Conecte-se a um banco de dados antes de executar consultas.');
      return;
    }

    final selection = tab.sqlController.selection;
    String rawSql = '';
    if (!selection.isCollapsed && selection.start != selection.end) {
      final start = selection.start < selection.end ? selection.start : selection.end;
      final end = selection.start < selection.end ? selection.end : selection.start;
      rawSql = tab.sqlController.text.substring(start, end).trim();
    } else {
      rawSql = tab.sqlController.text.trim();
    }
    if (rawSql.isEmpty) return;

    final statements = _splitSqlStatements(rawSql);
    if (statements.isEmpty) return;

    setState(() => tab.isRunning = true);

    final resultsList = <DbQueryResult>[];
    for (final stmt in statements) {
      // Safety check for production environment
      if (_activeConnection?.environment == DbEnvironment.production) {
        final upper = stmt.toUpperCase();
        if (upper.contains('DROP ') || upper.contains('TRUNCATE ') || upper.contains('DELETE ') || upper.contains('UPDATE ')) {
          final confirm = await _showProductionWarningDialog(stmt);
          if (!confirm) {
            setState(() => tab.isRunning = false);
            return;
          }
        }
      }

      final res = await _activeClient!.executeQuery(stmt, maxRows: 1000);
      resultsList.add(res);
      if (res.hasError) break; // Interrompe no primeiro erro
    }

    if (mounted) {
      setState(() {
        tab.results = resultsList;
        tab.selectedResultIndex = 0;
        tab.isRunning = false;
        tab.pageIndex = 0;
      });
    }
  }

  Future<bool> _showProductionWarningDialog(String sql) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444)),
                SizedBox(width: 8),
                Text('Atenção: Ambiente de Produção'),
              ],
            ),
            content: Text(
              'Você está prestes a executar um comando de alteração/exclusão em um banco de PRODUÇÃO:\n\n$sql\n\nDeseja realmente continuar?',
            ),
            backgroundColor: widget.isDark ? const Color(0xFF162032) : Colors.white,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Executar em Produção', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: widget.isDark ? const Color(0xFF162032) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: Color(0xFFEF4444)),
            const SizedBox(width: 8),
            Text(title),
          ],
        ),
        content: SelectableText(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _openCreateOrEditDialog([DbConnectionConfig? existing]) async {
    final result = await showDialog<DbConnectionConfig>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => DbConnectionEditorDialog(
        isDark: widget.isDark,
        existing: existing,
        sshHosts: _sshHosts,
        tunnelManager: _tunnelManager,
      ),
    );

    if (result != null) {
      setState(() {
        if (existing != null) {
          final idx = _connections.indexWhere((c) => c.id == existing.id);
          if (idx >= 0) _connections[idx] = result;
        } else {
          _connections.add(result);
        }
      });
      _saveConnections();
    }
  }

  void _deleteConnection(DbConnectionConfig conn) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: widget.isDark ? const Color(0xFF162032) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Excluir Conexão'),
        content: Text('Tem certeza que deseja remover a conexão "${conn.name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            onPressed: () {
              setState(() {
                if (_activeConnection?.id == conn.id) {
                  _disconnectActive();
                }
                _connections.removeWhere((c) => c.id == conn.id);
              });
              conn.clearSecretsFromVault(_vault);
              _saveConnections();
              Navigator.pop(ctx);
            },
            child: const Text('Excluir', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final bgCol = isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9);
    final cardBg = isDark ? const Color(0xFF162032) : Colors.white;
    final borderCol = isDark ? const Color(0xFF26354D) : const Color(0xFFE2E8F0);

    return Scaffold(
      backgroundColor: bgCol,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Sidebar
          SizedBox(
            width: 320,
            child: _buildSidebar(cardBg, borderCol, isDark),
          ),
          VerticalDivider(width: 1, thickness: 1, color: borderCol),
          // Main Workspace
          Expanded(
            child: _buildWorkspace(cardBg, borderCol, isDark),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar(Color cardBg, Color borderCol, bool isDark) {
    return Container(
      color: cardBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.storage_rounded, size: 20, color: Color(0xFF10B981)),
                const SizedBox(width: 8),
                const Text('Conexões', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const Spacer(),
                IconButton.filledTonal(
                  onPressed: () => _openCreateOrEditDialog(),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  tooltip: 'Nova Conexão de Banco',
                  style: IconButton.styleFrom(padding: const EdgeInsets.all(6)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Active Connection Status Banner
          if (_activeConnection != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: _activeConnection!.environment.color.withValues(alpha: 0.12),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: _activeConnection!.environment.color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_activeConnection!.name} (${_activeConnection!.engine.label})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _activeConnection!.environment.color),
                    ),
                  ),
                  IconButton(
                    onPressed: _refreshTree,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    tooltip: 'Recarregar Árvore',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _disconnectActive,
                    icon: const Icon(Icons.power_settings_new_rounded, size: 16, color: Color(0xFFEF4444)),
                    tooltip: 'Desconectar',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),

          // Main Sidebar Content: Connection list OR Metadata Tree
          Expanded(
            child: _activeConnection == null
                ? _buildConnectionsListView(isDark)
                : _buildMetadataTreeView(isDark),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionsListView(bool isDark) {
    if (_connections.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.dns_outlined, size: 42, color: isDark ? Colors.white24 : Colors.black26),
              const SizedBox(height: 8),
              const Text('Nenhum banco cadastrado', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                'Cadastre conexões para PostgreSQL, MySQL ou SQL Server com túnel SSH integrado.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () => _openCreateOrEditDialog(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Cadastrar Banco'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: DbEnvironment.values.map((env) {
        final conns = _connections.where((c) => c.environment == env).toList();
        if (conns.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: env.color, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Text(env.label.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: env.color)),
                  const SizedBox(width: 4),
                  Text('(${conns.length})', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
            ...conns.map((c) => _buildConnectionTile(c, isDark)),
            const SizedBox(height: 6),
          ],
        );
      }).toList(),
    );
  }

  Widget _buildConnectionTile(DbConnectionConfig conn, bool isDark) {
    final isActive = _activeConnection?.id == conn.id;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isActive ? conn.engine.brandColor.withValues(alpha: 0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isActive ? conn.engine.brandColor.withValues(alpha: 0.4) : Colors.transparent,
        ),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        leading: Icon(conn.engine.iconData, color: conn.engine.brandColor, size: 22),
        title: Text(conn.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        subtitle: Text(
          '${conn.host}:${conn.port}${conn.databaseName.isNotEmpty ? " / ${conn.databaseName}" : ""}',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (conn.useSshTunnel)
              const Tooltip(
                message: 'Túnel SSH Habilitado',
                child: Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(Icons.hub_rounded, size: 15, color: Color(0xFF38BDF8)),
                ),
              ),
            IconButton(
              icon: _isConnecting && isActive
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(isActive ? Icons.power_settings_new_rounded : Icons.play_arrow_rounded,
                      size: 18, color: isActive ? const Color(0xFFEF4444) : const Color(0xFF10B981)),
              tooltip: isActive ? 'Desconectar' : 'Conectar ao Banco',
              onPressed: () => isActive ? _disconnectActive() : _connectTo(conn),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, size: 16),
              itemBuilder: (ctx) => [
                const PopupMenuItem(value: 'edit', child: Text('Editar')),
                const PopupMenuItem(value: 'duplicate', child: Text('Duplicar')),
                const PopupMenuItem(value: 'delete', child: Text('Excluir', style: TextStyle(color: Color(0xFFEF4444)))),
              ],
              onSelected: (val) {
                if (val == 'edit') _openCreateOrEditDialog(conn);
                if (val == 'duplicate') {
                  final dup = conn.copyWith(name: '${conn.name} (Cópia)');
                  setState(() => _connections.add(dup));
                  _saveConnections();
                }
                if (val == 'delete') _deleteConnection(conn);
              },
            ),
          ],
        ),
        onTap: () => isActive ? null : _connectTo(conn),
      ),
    );
  }

  Widget _buildMetadataTreeView(bool isDark) {
    return Column(
      children: [
        // Table Search & Filter input
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Filtrar tabelas, views...',
              prefixIcon: const Icon(Icons.search, size: 16),
              suffixIcon: _treeSearchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 14),
                      onPressed: () => setState(() => _treeSearchQuery = ''),
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
            style: const TextStyle(fontSize: 12),
            onChanged: (val) => setState(() => _treeSearchQuery = val.trim()),
          ),
        ),
        const Divider(height: 1),

        // Tree List (DBeaver style)
        Expanded(
          child: ListView.builder(
            itemCount: _schemas.length,
            itemBuilder: (ctx, idx) {
              final schema = _schemas[idx];
              final isDbExpanded = _expandedDatabases.contains(schema) || _treeSearchQuery.isNotEmpty;
              final isSelected = schema == _selectedSchema;
              final tables = _databaseTables[schema];
              final views = _databaseViews[schema];
              final functions = _databaseFunctions[schema];

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Database Node
                  InkWell(
                    onTap: () async {
                      setState(() {
                        if (_expandedDatabases.contains(schema)) {
                          _expandedDatabases.remove(schema);
                        } else {
                          _expandedDatabases.add(schema);
                        }
                        _selectedSchema = schema;
                      });
                      if (!_databaseTables.containsKey(schema)) {
                        await _loadSchemaContent(schema);
                      }
                    },
                    onSecondaryTapDown: (details) => _showDatabaseContextMenu(context, details.globalPosition, schema),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      color: isSelected
                          ? (_activeConnection?.engine.brandColor ?? Colors.blue).withValues(alpha: 0.08)
                          : Colors.transparent,
                      child: Row(
                        children: [
                          Icon(
                            isDbExpanded ? Icons.arrow_drop_down_rounded : Icons.arrow_right_rounded,
                            size: 20,
                            color: Colors.grey,
                          ),
                          Icon(
                            Icons.storage_rounded,
                            size: 16,
                            color: _activeConnection?.engine.brandColor ?? const Color(0xFF38BDF8),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              schema,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.bold,
                                color: isSelected ? (_activeConnection?.engine.brandColor ?? Colors.blue) : null,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isSelected)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              margin: const EdgeInsets.only(right: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text('ativo', style: TextStyle(fontSize: 9.5, color: Color(0xFF10B981), fontWeight: FontWeight.bold)),
                            ),
                          Builder(
                            builder: (ctx) => IconButton(
                              icon: const Icon(Icons.more_vert_rounded, size: 15, color: Colors.grey),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              tooltip: 'Opções do banco',
                              onPressed: () {
                                final box = ctx.findRenderObject() as RenderBox?;
                                final offset = box != null ? box.localToGlobal(Offset(0, box.size.height)) : Offset.zero;
                                _showDatabaseContextMenu(context, offset, schema);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // If database is expanded: Folders (Tabelas, Views, Functions)
                  if (isDbExpanded) ...[
                    // Folder 1: Tabelas
                    _buildTreeFolder(
                      schema: schema,
                      folderKey: '$schema:tables',
                      title: 'Tabelas',
                      icon: Icons.table_chart_rounded,
                      iconColor: const Color(0xFF38BDF8),
                      items: tables,
                      itemIcon: Icons.table_rows_rounded,
                      itemColor: const Color(0xFF38BDF8),
                      isView: false,
                      isDark: isDark,
                    ),

                    // Folder 2: Views
                    _buildTreeFolder(
                      schema: schema,
                      folderKey: '$schema:views',
                      title: 'Views',
                      icon: Icons.visibility_rounded,
                      iconColor: const Color(0xFF818CF8),
                      items: views,
                      itemIcon: Icons.visibility_outlined,
                      itemColor: const Color(0xFF818CF8),
                      isView: true,
                      isDark: isDark,
                    ),

                    // Folder 3: Funções & Procedures
                    _buildTreeFunctionFolder(
                      schema: schema,
                      folderKey: '$schema:functions',
                      title: 'Funções & Procedures',
                      icon: Icons.functions_rounded,
                      iconColor: const Color(0xFF10B981),
                      functions: functions,
                      isDark: isDark,
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTreeFolder({
    required String schema,
    required String folderKey,
    required String title,
    required IconData icon,
    required Color iconColor,
    required List<String>? items,
    required IconData itemIcon,
    required Color itemColor,
    required bool isView,
    required bool isDark,
  }) {
    final isFolderExpanded = _expandedFolders.contains(folderKey) || _treeSearchQuery.isNotEmpty;
    final filtered = items == null
        ? null
        : (_treeSearchQuery.isEmpty
            ? items
            : items.where((i) => i.toLowerCase().contains(_treeSearchQuery.toLowerCase())).toList());

    if (_treeSearchQuery.isNotEmpty && (filtered == null || filtered.isEmpty)) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Folder Header
        InkWell(
          onTap: () {
            setState(() {
              if (_expandedFolders.contains(folderKey)) {
                _expandedFolders.remove(folderKey);
              } else {
                _expandedFolders.add(folderKey);
              }
            });
          },
          child: Padding(
            padding: const EdgeInsets.only(left: 20, top: 4, bottom: 4, right: 8),
            child: Row(
              children: [
                Icon(
                  isFolderExpanded ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_right_rounded,
                  size: 16,
                  color: Colors.grey,
                ),
                const SizedBox(width: 2),
                const Icon(Icons.folder_rounded, size: 16, color: Color(0xFFF59E0B)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '$title ${items != null ? "(${items.length})" : ""}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Items inside folder
        if (isFolderExpanded) ...[
          if (items == null)
            const Padding(
              padding: EdgeInsets.only(left: 48, top: 4, bottom: 4),
              child: SizedBox(height: 12, width: 120, child: LinearProgressIndicator()),
            )
          else if (filtered!.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 48, top: 4, bottom: 4),
              child: Text(
                'Nenhum item.',
                style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black38, fontStyle: FontStyle.italic),
              ),
            )
          else
            ...filtered.map((item) {
              final tableKey = '$schema:$item';
              final isTableExpanded = _expandedTables.contains(tableKey);
              final cachedCols = _tableColumnsCache[tableKey];

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onSecondaryTapDown: (details) {
                      _showTableContextMenu(context, details.globalPosition, schema, item, isView: isView);
                    },
                    child: InkWell(
                      onTap: () {
                        if (isView) {
                          _selectTop1000(schema, item);
                        } else {
                          _openTableTab(item, schema: schema);
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(left: 36, top: 2, bottom: 2, right: 6),
                        child: Row(
                          children: [
                            if (!isView)
                              InkWell(
                                onTap: () async {
                                  setState(() {
                                    if (isTableExpanded) {
                                      _expandedTables.remove(tableKey);
                                    } else {
                                      _expandedTables.add(tableKey);
                                    }
                                  });
                                  if (!isTableExpanded && cachedCols == null && _activeClient != null) {
                                    final cols = await _activeClient!.getTableColumns(item, schema: schema);
                                    if (mounted) setState(() => _tableColumnsCache[tableKey] = cols);
                                  }
                                },
                                child: Icon(
                                  isTableExpanded ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_right_rounded,
                                  size: 16,
                                  color: Colors.grey,
                                ),
                              )
                            else
                              const SizedBox(width: 16),
                            const SizedBox(width: 2),
                            Icon(itemIcon, size: 15, color: itemColor),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                item,
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.more_vert_rounded, size: 14, color: Colors.grey),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              tooltip: 'Opções da Tabela',
                              onPressed: () {
                                final renderBox = context.findRenderObject() as RenderBox?;
                                final offset = renderBox?.localToGlobal(Offset.zero) ?? const Offset(200, 200);
                                _showTableContextMenu(context, offset, schema, item, isView: isView);
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Column list inside table
                  if (isTableExpanded)
                    Padding(
                      padding: const EdgeInsets.only(left: 58, right: 8, bottom: 4),
                      child: cachedCols == null
                          ? const SizedBox(height: 12, width: 100, child: LinearProgressIndicator())
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: cachedCols.map((col) {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 1.5),
                                  child: Row(
                                    children: [
                                      Icon(
                                        col.isPrimaryKey ? Icons.key_rounded : Icons.lens_rounded,
                                        size: col.isPrimaryKey ? 12 : 5,
                                        color: col.isPrimaryKey ? const Color(0xFFF59E0B) : Colors.grey,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          col.name,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: col.isPrimaryKey ? FontWeight.bold : FontWeight.normal,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Text(
                                        col.dataType,
                                        style: const TextStyle(fontSize: 10, color: Colors.grey, fontFamily: 'monospace'),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                    ),
                ],
              );
            }),
        ],
      ],
    );
  }

  Widget _buildTreeFunctionFolder({
    required String schema,
    required String folderKey,
    required String title,
    required IconData icon,
    required Color iconColor,
    required List<String>? functions,
    required bool isDark,
  }) {
    final isFolderExpanded = _expandedFolders.contains(folderKey) || _treeSearchQuery.isNotEmpty;
    final filtered = functions == null
        ? null
        : (_treeSearchQuery.isEmpty
            ? functions
            : functions.where((f) => f.toLowerCase().contains(_treeSearchQuery.toLowerCase())).toList());

    if (_treeSearchQuery.isNotEmpty && (filtered == null || filtered.isEmpty)) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              if (_expandedFolders.contains(folderKey)) {
                _expandedFolders.remove(folderKey);
              } else {
                _expandedFolders.add(folderKey);
              }
            });
          },
          child: Padding(
            padding: const EdgeInsets.only(left: 20, top: 4, bottom: 4, right: 8),
            child: Row(
              children: [
                Icon(
                  isFolderExpanded ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_right_rounded,
                  size: 16,
                  color: Colors.grey,
                ),
                const SizedBox(width: 2),
                const Icon(Icons.folder_rounded, size: 16, color: Color(0xFFF59E0B)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '$title ${functions != null ? "(${functions.length})" : ""}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (isFolderExpanded) ...[
          if (functions == null)
            const Padding(
              padding: EdgeInsets.only(left: 48, top: 4, bottom: 4),
              child: SizedBox(height: 12, width: 120, child: LinearProgressIndicator()),
            )
          else if (filtered!.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 48, top: 4, bottom: 4),
              child: Text(
                'Nenhuma função.',
                style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black38, fontStyle: FontStyle.italic),
              ),
            )
          else
            ...filtered.map((fn) {
              return InkWell(
                onTap: () {
                  _addNewQueryTab(initialSql: '-- Chamada para $fn\nSELECT ${_formatTableName(schema, fn)}();\n');
                },
                child: Padding(
                  padding: const EdgeInsets.only(left: 36, top: 2, bottom: 2, right: 6),
                  child: Row(
                    children: [
                      const SizedBox(width: 16),
                      Icon(icon, size: 14, color: iconColor),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          fn,
                          style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ],
    );
  }

  Widget _buildWorkspace(Color cardBg, Color borderCol, bool isDark) {
    if (_tabs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal_rounded, size: 56, color: isDark ? Colors.white24 : Colors.black26),
            const SizedBox(height: 12),
            const Text('Nenhum editor aberto', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              'Abra uma nova consulta SQL ou selecione uma tabela no painel lateral.',
              style: TextStyle(fontSize: 13, color: isDark ? Colors.white54 : Colors.black54),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                  onPressed: () => _addNewQueryTab(),
                  icon: const Icon(Icons.post_add_rounded, size: 18),
                  label: const Text('Nova Consulta SQL'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                  onPressed: () => _openQueryFromFile(),
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('Abrir Arquivo .sql'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Tab Header Bar (Beekeeper style)
        Container(
          color: cardBg,
          height: 40,
          child: Row(
            children: [
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _tabs.length,
                  itemBuilder: (ctx, i) {
                    final tab = _tabs[i];
                    final isSel = _activeTabIndex == i;
                    return GestureDetector(
                      onTap: () => setState(() => _activeTabIndex = i),
                      onSecondaryTapDown: tab is QueryTabItem
                          ? (details) => _showQueryTabContextMenu(context, details.globalPosition, tab, i)
                          : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: isSel ? (isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9)) : Colors.transparent,
                          border: Border(
                            bottom: BorderSide(
                              color: isSel ? const Color(0xFF10B981) : Colors.transparent,
                              width: 2.5,
                            ),
                            right: BorderSide(color: borderCol, width: 1),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(tab.icon, size: 15, color: isSel ? const Color(0xFF10B981) : Colors.grey),
                            const SizedBox(width: 8),
                            Text(
                              tab.title,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () => _closeTab(i),
                              child: const Icon(Icons.close_rounded, size: 14, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              IconButton(
                onPressed: () => _openQueryFromFile(),
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                tooltip: 'Abrir Arquivo .sql do Disco',
              ),
              IconButton(
                onPressed: () => _addNewQueryTab(),
                icon: const Icon(Icons.add_rounded, size: 18),
                tooltip: 'Nova Aba SQL',
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Tab Content
        Expanded(
          child: IndexedStack(
            index: _activeTabIndex,
            children: _tabs.map((tab) {
              if (tab is QueryTabItem) {
                return _buildQueryTabContent(tab, isDark, borderCol);
              } else if (tab is TableTabItem) {
                return _buildTableTabContent(tab, isDark, borderCol);
              }
              return const SizedBox.shrink();
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildQueryTabContent(QueryTabItem tab, bool isDark, Color borderCol) {
    final activeResult = tab.currentResult;
    return Column(
      children: [
        // SQL Editor Panel
        Expanded(
          flex: 4,
          child: Container(
            color: isDark ? const Color(0xFF0F172A) : Colors.white,
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Toolbar
                Row(
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      ),
                      onPressed: tab.isRunning ? null : () => _executeQuery(tab),
                      icon: tab.isRunning
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.play_arrow_rounded, size: 18),
                      label: const Text('Executar (Ctrl+Enter)'),
                    ),
                    const SizedBox(width: 10),
                    // Database Schema Selector
                    if (_schemas.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        height: 32,
                        decoration: BoxDecoration(
                          border: Border.all(color: isDark ? Colors.white24 : Colors.black26),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _schemas.contains(tab.selectedSchema)
                                ? tab.selectedSchema
                                : (_schemas.isNotEmpty ? _schemas.first : null),
                            isDense: true,
                            style: TextStyle(fontSize: 12, color: isDark ? Colors.white : Colors.black87),
                            hint: const Text('Banco de Dados', style: TextStyle(fontSize: 12)),
                            items: _schemas.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                            onChanged: (val) {
                              if (val != null) setState(() => tab.selectedSchema = val);
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    // Save and Save As
                    IconButton(
                      icon: Icon(Icons.save_rounded, size: 18, color: tab.isDirty ? const Color(0xFFF59E0B) : null),
                      tooltip: tab.filePath != null ? 'Salvar (${tab.filePath}) [Ctrl+S]' : 'Salvar Consulta (.sql) [Ctrl+S]',
                      onPressed: () => _saveQueryTab(tab),
                    ),
                    IconButton(
                      icon: const Icon(Icons.save_as_rounded, size: 18),
                      tooltip: 'Salvar Como...',
                      onPressed: () => _saveQueryTabAs(tab),
                    ),
                    IconButton(
                      icon: const Icon(Icons.folder_open_rounded, size: 18),
                      tooltip: 'Abrir Arquivo .sql',
                      onPressed: () => _openQueryFromFile(),
                    ),
                    const SizedBox(width: 8),
                    if (activeResult != null) ...[
                      Chip(
                        label: Text('⏱️ ${activeResult.executionTimeMs} ms', style: const TextStyle(fontSize: 11)),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                      const SizedBox(width: 8),
                      Chip(
                        label: Text(
                          '📊 ${activeResult.isSelect ? "${activeResult.rows.length} linhas" : "${activeResult.affectedRows} afetadas"}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.clear_all_rounded, size: 18),
                      tooltip: 'Limpar Editor',
                      onPressed: () => tab.sqlController.clear(),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Text Area with Shortcuts and Intellisense listener
                Expanded(
                  child: Shortcuts(
                    shortcuts: {
                      LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.enter): const ActivateIntent(),
                      LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyS): const _SaveSqlIntent(),
                    },
                    child: Actions(
                      actions: {
                        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _executeQuery(tab)),
                        _SaveSqlIntent: CallbackAction<_SaveSqlIntent>(onInvoke: (_) => _saveQueryTab(tab)),
                      },
                      child: TextField(
                        controller: tab.sqlController,
                        maxLines: null,
                        expands: true,
                        onChanged: (_) => _onSqlTextChanged(tab),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.4,
                        ),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Escreva sua consulta SQL aqui...\nDica: Selecione uma linha ou consulta específica para rodar somente ela.',
                          hintStyle: TextStyle(
                            fontSize: 12.5,
                            color: isDark ? Colors.white24 : Colors.black26,
                            fontFamily: 'sans-serif',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Intellisense Suggestion Chips
                if (tab.currentSuggestions.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.auto_awesome_rounded, size: 14, color: Color(0xFF10B981)),
                        const SizedBox(width: 6),
                        const Text('Sugestões: ', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 4),
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: tab.currentSuggestions.map((s) {
                                return Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: ActionChip(
                                    avatar: Icon(s.icon, size: 13, color: s.color),
                                    label: Text('${s.label} (${s.category})', style: const TextStyle(fontSize: 11)),
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    onPressed: () => _applySuggestion(tab, s),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 14),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: 'Fechar sugestões',
                          onPressed: () => setState(() => tab.currentSuggestions = []),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        Divider(height: 1, thickness: 1, color: borderCol),

        // Multi-result Switcher Bar (if more than 1 query result)
        if (tab.results.length > 1)
          Container(
            height: 34,
            color: isDark ? const Color(0xFF162032) : const Color(0xFFE2E8F0),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: tab.results.length,
              itemBuilder: (ctx, rIdx) {
                final isResSelected = tab.selectedResultIndex == rIdx;
                final resItem = tab.results[rIdx];
                final label = 'Resultado ${rIdx + 1}: ${resItem.isSelect ? "${resItem.rows.length} lin" : "${resItem.affectedRows} afet"}';
                return InkWell(
                  onTap: () => setState(() {
                    tab.selectedResultIndex = rIdx;
                    tab.pageIndex = 0;
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isResSelected ? (isDark ? const Color(0xFF0F172A) : Colors.white) : Colors.transparent,
                      border: Border(
                        bottom: BorderSide(
                          color: isResSelected ? const Color(0xFF10B981) : Colors.transparent,
                          width: 2,
                        ),
                        right: BorderSide(color: borderCol, width: 1),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          resItem.hasError ? Icons.error_outline : Icons.check_circle_outline,
                          size: 14,
                          color: resItem.hasError ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: isResSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

        // Results Panel
        Expanded(
          flex: 6,
          child: _buildResultsGrid(
            tab.currentResult,
            tab.pageIndex,
            tab.pageSize,
            (idx) => setState(() => tab.pageIndex = idx),
            (size) => setState(() => tab.pageSize = size),
            tab.verticalScroll,
            tab.horizontalScroll,
            isDark,
          ),
        ),
      ],
    );
  }

  Widget _buildTableTabContent(TableTabItem tab, bool isDark, Color borderCol) {
    return Column(
      children: [
        // Sub-tabs switcher (DBeaver style: Dados | Estrutura | Chaves Estrangeiras | DDL)
        Container(
          color: isDark ? const Color(0xFF162032) : Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              SegmentedButton<int>(
                segments: [
                  const ButtonSegment(value: 0, label: Text('📊 Dados'), icon: Icon(Icons.table_rows_rounded, size: 16)),
                  const ButtonSegment(value: 1, label: Text('⚙️ Estrutura'), icon: Icon(Icons.schema_rounded, size: 16)),
                  ButtonSegment(
                    value: 2,
                    label: Text('🔗 Chaves Estrangeiras (${tab.foreignKeys.length + tab.referencingKeys.length})'),
                    icon: const Icon(Icons.link_rounded, size: 16),
                  ),
                  const ButtonSegment(value: 3, label: Text('📜 DDL / SQL'), icon: Icon(Icons.code_rounded, size: 16)),
                ],
                selected: {tab.subTabIndex},
                onSelectionChanged: (set) => setState(() => tab.subTabIndex = set.first),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 18),
                tooltip: 'Recarregar Tabela',
                onPressed: () => _loadTableData(tab),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Sub-tab view
        Expanded(
          child: tab.isLoading
              ? const Center(child: CircularProgressIndicator())
              : IndexedStack(
                  index: tab.subTabIndex,
                  children: [
                    // Sub-tab 0: Dados (with Foreign Key Navigation)
                    _buildResultsGrid(
                      tab.dataResult,
                      tab.pageIndex,
                      tab.pageSize,
                      (idx) => setState(() => tab.pageIndex = idx),
                      (size) => setState(() => tab.pageSize = size),
                      tab.verticalScroll,
                      tab.horizontalScroll,
                      isDark,
                      foreignKeys: tab.foreignKeys,
                      referencingKeys: tab.referencingKeys,
                      currentSchema: tab.schema,
                      currentTable: tab.tableName,
                    ),

                    // Sub-tab 1: Estrutura (Colunas, tipos, PK, FK)
                    _buildStructureGrid(tab.columns, isDark, foreignKeys: tab.foreignKeys),

                    // Sub-tab 2: Chaves Estrangeiras (Outbound & Inbound)
                    _buildForeignKeysView(tab, isDark),

                    // Sub-tab 3: DDL
                    _buildDdlView(tab.ddl, isDark),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildStructureGrid(List<TableColumnMetadata>? columns, bool isDark, {List<TableForeignKey>? foreignKeys}) {
    if (columns == null || columns.isEmpty) {
      return const Center(child: Text('Nenhuma coluna disponível.'));
    }

    TableForeignKey? getFk(String colName) {
      if (foreignKeys == null) return null;
      try {
        return foreignKeys.firstWhere((f) => f.fromColumn.toLowerCase() == colName.toLowerCase());
      } catch (_) {
        return null;
      }
    }

    return Scrollbar(
      thumbVisibility: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Nome da Coluna', style: TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text('Tipo de Dado', style: TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text('Nullable', style: TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text('Chave / Relação', style: TextStyle(fontWeight: FontWeight.bold))),
              DataColumn(label: Text('Valor Padrão', style: TextStyle(fontWeight: FontWeight.bold))),
            ],
            rows: columns.map((c) {
              final fk = getFk(c.name);
              return DataRow(
                cells: [
                  DataCell(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (c.isPrimaryKey) ...[
                          const Icon(Icons.key_rounded, size: 14, color: Color(0xFFF59E0B)),
                          const SizedBox(width: 6),
                        ] else if (fk != null) ...[
                          const Icon(Icons.link_rounded, size: 14, color: Color(0xFF38BDF8)),
                          const SizedBox(width: 6),
                        ],
                        Text(c.name, style: TextStyle(fontWeight: c.isPrimaryKey ? FontWeight.bold : FontWeight.normal)),
                      ],
                    ),
                  ),
                  DataCell(Text(c.dataType, style: const TextStyle(fontFamily: 'monospace'))),
                  DataCell(Text(c.isNullable ? 'SIM' : 'NÃO', style: TextStyle(color: c.isNullable ? Colors.grey : const Color(0xFFEF4444)))),
                  DataCell(
                    c.isPrimaryKey
                        ? const Text('🔑 Chave Primária (PK)', style: TextStyle(color: Color(0xFFF59E0B), fontWeight: FontWeight.bold))
                        : (fk != null
                            ? InkWell(
                                onTap: () => _openTableTab(fk.toTable, schema: fk.toSchema),
                                child: Text('🔗 FK -> ${fk.toTable}.${fk.toColumn}',
                                    style: const TextStyle(color: Color(0xFF38BDF8), decoration: TextDecoration.underline)),
                              )
                            : const Text('-')),
                  ),
                  DataCell(Text(c.defaultValue ?? '-')),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildForeignKeysView(TableTabItem tab, bool isDark) {
    final fks = tab.foreignKeys;
    final refs = tab.referencingKeys;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Section 1: Outbound Foreign Keys
          Card(
            color: isDark ? const Color(0xFF162032) : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: isDark ? const Color(0xFF26354D) : const Color(0xFFE2E8F0)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.link_rounded, color: Color(0xFF38BDF8), size: 20),
                      SizedBox(width: 8),
                      Text('Chaves Estrangeiras Desta Tabela (Outbound)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('Colunas desta tabela que apontam para chaves primárias em outras tabelas.',
                      style: TextStyle(fontSize: 12, color: isDark ? Colors.white54 : Colors.black54)),
                  const SizedBox(height: 12),
                  if (fks.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('Nenhuma chave estrangeira configurada nesta tabela.',
                          style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12, color: Colors.grey)),
                    )
                  else
                    DataTable(
                      columns: const [
                        DataColumn(label: Text('Constraint', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('Coluna Origem', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('Tabela Destino', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('Coluna Destino', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('Ação', style: TextStyle(fontWeight: FontWeight.bold))),
                      ],
                      rows: fks.map((fk) {
                        return DataRow(
                          cells: [
                            DataCell(Text(fk.constraintName, style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'))),
                            DataCell(Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.key_rounded, size: 13, color: Color(0xFF38BDF8)),
                                const SizedBox(width: 4),
                                Text(fk.fromColumn, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              ],
                            )),
                            DataCell(Text(fk.toTable, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold))),
                            DataCell(Text(fk.toColumn, style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'))),
                            DataCell(
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF38BDF8),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () {
                                  _openTableTab(fk.toTable, schema: fk.toSchema.isEmpty ? tab.schema : fk.toSchema);
                                },
                                icon: const Icon(Icons.open_in_new_rounded, size: 14),
                                label: const Text('Abrir Tabela', style: TextStyle(fontSize: 11)),
                              ),
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Section 2: Inbound / Referencing Keys
          Card(
            color: isDark ? const Color(0xFF162032) : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: isDark ? const Color(0xFF26354D) : const Color(0xFFE2E8F0)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.hub_rounded, color: Color(0xFF10B981), size: 20),
                      SizedBox(width: 8),
                      Text('Tabelas que Referenciam Esta Tabela (Dependentes)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('Outras tabelas que possuem chaves estrangeiras apontando para esta tabela.',
                      style: TextStyle(fontSize: 12, color: isDark ? Colors.white54 : Colors.black54)),
                  const SizedBox(height: 12),
                  if (refs.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('Nenhuma tabela dependente encontrada.',
                          style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12, color: Colors.grey)),
                    )
                  else
                    DataTable(
                      columns: const [
                        DataColumn(label: Text('Tabela Dependente', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('Coluna FK', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('Aponta para Coluna', style: TextStyle(fontWeight: FontWeight.bold))),
                        DataColumn(label: Text('Ação', style: TextStyle(fontWeight: FontWeight.bold))),
                      ],
                      rows: refs.map((ref) {
                        return DataRow(
                          cells: [
                            DataCell(Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.table_chart_rounded, size: 14, color: Color(0xFF10B981)),
                                const SizedBox(width: 6),
                                Text(ref.fromTable, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                              ],
                            )),
                            DataCell(Text(ref.fromColumn, style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'))),
                            DataCell(Text(ref.toColumn, style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'))),
                            DataCell(
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF10B981),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () {
                                  _openTableTab(ref.fromTable, schema: ref.fromSchema.isEmpty ? tab.schema : ref.fromSchema);
                                },
                                icon: const Icon(Icons.open_in_new_rounded, size: 14),
                                label: const Text('Abrir Tabela', style: TextStyle(fontSize: 11)),
                              ),
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDdlView(String? ddl, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Definição DDL (CREATE TABLE):', style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () {
                  if (ddl != null) {
                    Clipboard.setData(ClipboardData(text: ddl));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('DDL copiado para a área de transferência!')));
                  }
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('Copiar DDL'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: isDark ? const Color(0xFF26354D) : const Color(0xFFE2E8F0)),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  ddl ?? '-- DDL indisponível.',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showCellNavigationContextMenu(
    BuildContext context,
    Offset position, {
    required String text,
    required String column,
    TableForeignKey? fk,
    List<TableForeignKey>? referencingKeys,
    required String currentSchema,
  }) {
    final textStyle = TextStyle(fontSize: 12, color: widget.isDark ? Colors.white : Colors.black87);
    final items = <PopupMenuEntry<String>>[];

    if (fk != null && text.isNotEmpty && text != 'NULL') {
      items.add(PopupMenuItem(
        value: 'navigate_fk',
        child: Row(
          children: [
            const Icon(Icons.open_in_new_rounded, size: 15, color: Color(0xFF38BDF8)),
            const SizedBox(width: 8),
            Text('Ir para ${fk.toTable} (${fk.toColumn} = $text)', style: textStyle),
          ],
        ),
      ));
    }

    if (referencingKeys != null && referencingKeys.isNotEmpty && text.isNotEmpty && text != 'NULL') {
      if (items.isNotEmpty) items.add(const PopupMenuDivider());
      for (int i = 0; i < referencingKeys.length; i++) {
        final ref = referencingKeys[i];
        items.add(PopupMenuItem(
          value: 'ref_$i',
          child: Row(
            children: [
              const Icon(Icons.hub_rounded, size: 15, color: Color(0xFF10B981)),
              const SizedBox(width: 8),
              Text('Ver registros em ${ref.fromTable} (${ref.fromColumn} = $text)', style: textStyle),
            ],
          ),
        ));
      }
    }

    if (items.isNotEmpty) items.add(const PopupMenuDivider());
    items.add(PopupMenuItem(
      value: 'copy',
      child: Row(
        children: [
          const Icon(Icons.copy_rounded, size: 15, color: Colors.grey),
          const SizedBox(width: 8),
          Text('Copiar "$text"', style: textStyle),
        ],
      ),
    ));

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx + 1, position.dy + 1),
      items: items,
    ).then((val) {
      if (val == 'navigate_fk' && fk != null) {
        _navigateForeignKey(fk.toSchema.isEmpty ? currentSchema : fk.toSchema, fk.toTable, fk.toColumn, text);
      } else if (val != null && val.startsWith('ref_') && referencingKeys != null) {
        final idx = int.tryParse(val.substring(4));
        if (idx != null && idx < referencingKeys.length) {
          final ref = referencingKeys[idx];
          _navigateReferencingTable(ref.fromSchema.isEmpty ? currentSchema : ref.fromSchema, ref.fromTable, ref.fromColumn, text);
        }
      } else if (val == 'copy') {
        Clipboard.setData(ClipboardData(text: text));
      }
    });
  }

  Widget _buildResultsGrid(
    DbQueryResult? result,
    int pageIndex,
    int pageSize,
    Function(int) onPageChange,
    Function(int) onPageSizeChange,
    ScrollController verticalController,
    ScrollController horizontalController,
    bool isDark, {
    List<TableForeignKey>? foreignKeys,
    List<TableForeignKey>? referencingKeys,
    String? currentSchema,
    String? currentTable,
  }) {
    if (result == null) {
      return const Center(child: Text('Nenhum resultado para exibir.'));
    }

    if (result.hasError) {
      return Container(
        color: const Color(0xFFEF4444).withValues(alpha: 0.08),
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          'Erro ao executar consulta:\n${result.error}',
          style: const TextStyle(color: Color(0xFFEF4444), fontFamily: 'monospace', fontSize: 12.5),
        ),
      );
    }

    if (!result.isSelect) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline_rounded, color: Color(0xFF10B981), size: 40),
            const SizedBox(height: 10),
            Text('Comando executado com sucesso! (${result.affectedRows} linhas afetadas)',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      );
    }

    final totalRows = result.rows.length;
    final startIndex = pageIndex * pageSize;
    final endIndex = (startIndex + pageSize) > totalRows ? totalRows : (startIndex + pageSize);
    final displayedRows = (startIndex < totalRows) ? result.rows.sublist(startIndex, endIndex) : <List<dynamic>>[];

    TableForeignKey? getForeignKeyForColumn(String col) {
      if (foreignKeys == null || foreignKeys.isEmpty) return null;
      try {
        return foreignKeys.firstWhere((fk) => fk.fromColumn.toLowerCase() == col.toLowerCase());
      } catch (_) {
        return null;
      }
    }

    return Column(
      children: [
        // Export Toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: isDark ? const Color(0xFF162032) : Colors.white,
          child: Row(
            children: [
              Text('$totalRows registros retornados', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _exportCsv(result),
                icon: const Icon(Icons.table_view_rounded, size: 16),
                label: const Text('Exportar CSV', style: TextStyle(fontSize: 12)),
              ),
              TextButton.icon(
                onPressed: () => _exportJson(result),
                icon: const Icon(Icons.data_object_rounded, size: 16),
                label: const Text('Exportar JSON', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Grid Table with 2-axis Visible Scrollbars
        Expanded(
          child: Scrollbar(
            controller: horizontalController,
            thumbVisibility: true,
            trackVisibility: true,
            notificationPredicate: (notif) => notif.metrics.axis == Axis.horizontal,
            child: Scrollbar(
              controller: verticalController,
              thumbVisibility: true,
              trackVisibility: true,
              notificationPredicate: (notif) => notif.metrics.axis == Axis.vertical,
              child: SingleChildScrollView(
                controller: verticalController,
                scrollDirection: Axis.vertical,
                child: SingleChildScrollView(
                  controller: horizontalController,
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowHeight: 36,
                    dataRowMinHeight: 32,
                    dataRowMaxHeight: 36,
                    columns: result.columns.map((col) {
                      final fk = getForeignKeyForColumn(col);
                      return DataColumn(
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(col, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                            if (fk != null) ...[
                              const SizedBox(width: 4),
                              Tooltip(
                                message: 'Chave Estrangeira: aponta para ${fk.toTable}.${fk.toColumn}',
                                child: const Icon(Icons.link_rounded, size: 14, color: Color(0xFF38BDF8)),
                              ),
                            ],
                          ],
                        ),
                      );
                    }).toList(),
                    rows: displayedRows.map((row) {
                      return DataRow(
                        cells: List.generate(row.length, (colIdx) {
                          final cell = row[colIdx];
                          final colName = colIdx < result.columns.length ? result.columns[colIdx] : '';
                          final fk = getForeignKeyForColumn(colName);
                          final text = cell?.toString() ?? 'NULL';
                          final isNull = cell == null;

                          // Foreign Key direct clickable link
                          if (fk != null && !isNull && text.isNotEmpty && text != 'NULL') {
                            return DataCell(
                              InkWell(
                                borderRadius: BorderRadius.circular(4),
                                onTap: () => _navigateForeignKey(
                                  fk.toSchema.isNotEmpty ? fk.toSchema : (currentSchema ?? _selectedSchema),
                                  fk.toTable,
                                  fk.toColumn,
                                  text,
                                ),
                                child: Tooltip(
                                  message: '🔗 Navegar para ${fk.toTable} (${fk.toColumn} = $text)',
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          text,
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                            fontFamily: 'monospace',
                                            color: Color(0xFF38BDF8),
                                            fontWeight: FontWeight.bold,
                                            decoration: TextDecoration.underline,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        const Icon(Icons.open_in_new_rounded, size: 12, color: Color(0xFF38BDF8)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }

                          // Regular cell with context menu on secondary tap for navigation
                          return DataCell(
                            GestureDetector(
                              onSecondaryTapDown: (details) {
                                _showCellNavigationContextMenu(
                                  context,
                                  details.globalPosition,
                                  text: text,
                                  column: colName,
                                  fk: fk,
                                  referencingKeys: referencingKeys,
                                  currentSchema: currentSchema ?? _selectedSchema,
                                );
                              },
                              child: SelectableText(
                                text,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontFamily: 'monospace',
                                  color: isNull ? Colors.grey : null,
                                  fontStyle: isNull ? FontStyle.italic : FontStyle.normal,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
          ),
        ),
        const Divider(height: 1),

        // Pagination Bar with page size selector
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          color: isDark ? const Color(0xFF162032) : Colors.white,
          child: Row(
            children: [
              Text(
                'Exibindo ${totalRows == 0 ? 0 : startIndex + 1} - $endIndex de $totalRows',
                style: const TextStyle(fontSize: 11.5, color: Colors.grey),
              ),
              const SizedBox(width: 14),
              DropdownButton<int>(
                value: pageSize,
                isDense: true,
                underline: const SizedBox.shrink(),
                style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white70 : Colors.black87),
                items: const [25, 50, 100, 200, 500, 1000].map((size) {
                  return DropdownMenuItem(value: size, child: Text('$size / pág'));
                }).toList(),
                onChanged: (val) {
                  if (val != null) onPageSizeChange(val);
                },
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.first_page_rounded, size: 18),
                onPressed: pageIndex > 0 ? () => onPageChange(0) : null,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_left_rounded, size: 18),
                onPressed: pageIndex > 0 ? () => onPageChange(pageIndex - 1) : null,
              ),
              Text('Página ${totalRows == 0 ? 0 : pageIndex + 1}', style: const TextStyle(fontSize: 11.5)),
              IconButton(
                icon: const Icon(Icons.chevron_right_rounded, size: 18),
                onPressed: endIndex < totalRows ? () => onPageChange(pageIndex + 1) : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _exportCsv(DbQueryResult result) {
    final buf = StringBuffer();
    buf.writeln(result.columns.map((c) => '"$c"').join(','));
    for (final r in result.rows) {
      buf.writeln(r.map((v) => '"${v?.toString().replaceAll('"', '""') ?? ''}"').join(','));
    }
    Clipboard.setData(ClipboardData(text: buf.toString()));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Dados copiados como CSV!')));
  }

  void _exportJson(DbQueryResult result) {
    final list = <Map<String, dynamic>>[];
    for (final r in result.rows) {
      final map = <String, dynamic>{};
      for (int i = 0; i < result.columns.length; i++) {
        map[result.columns[i]] = i < r.length ? r[i] : null;
      }
      list.add(map);
    }
    const encoder = JsonEncoder.withIndent('  ');
    Clipboard.setData(ClipboardData(text: encoder.convert(list)));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Dados copiados como JSON!')));
  }
}

/// 2-Step Connection Creator & Editor Dialog (Beekeeper Studio + DBeaver style)
class DbConnectionEditorDialog extends StatefulWidget {
  final bool isDark;
  final DbConnectionConfig? existing;
  final List<SshHostConfig> sshHosts;
  final DbTunnelManager tunnelManager;

  const DbConnectionEditorDialog({
    super.key,
    required this.isDark,
    this.existing,
    required this.sshHosts,
    required this.tunnelManager,
  });

  @override
  State<DbConnectionEditorDialog> createState() => _DbConnectionEditorDialogState();
}

class _DbConnectionEditorDialogState extends State<DbConnectionEditorDialog> {
  late int _step; // 1: Selecionar Modelo, 2: Passar Dados de Conexão
  late DbEngine _selectedEngine;
  late DbEnvironment _selectedEnv;

  late final TextEditingController _nameCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _dbCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;

  late bool _useSshTunnel;
  late String _selectedSshHost;
  late bool _ssl;
  bool _obscurePassword = true;

  bool _isTesting = false;
  String? _testMessage;
  bool? _testSuccess;

  @override
  void initState() {
    super.initState();
    _step = widget.existing == null ? 1 : 2;
    _selectedEngine = widget.existing?.engine ?? DbEngine.postgres;
    _selectedEnv = widget.existing?.environment ?? DbEnvironment.development;

    _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
    _hostCtrl = TextEditingController(text: widget.existing?.host ?? '127.0.0.1');
    _portCtrl = TextEditingController(text: widget.existing?.port.toString() ?? _selectedEngine.defaultPort.toString());
    _dbCtrl = TextEditingController(text: widget.existing?.databaseName ?? '');
    _userCtrl = TextEditingController(text: widget.existing?.username ?? 'postgres');
    _passCtrl = TextEditingController(text: widget.existing?.password ?? '');

    _useSshTunnel = widget.existing?.useSshTunnel ?? false;
    _selectedSshHost = widget.existing?.sshHostId ?? (widget.sshHosts.isNotEmpty ? widget.sshHosts.first.id : '');
    _ssl = widget.existing?.ssl ?? false;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _dbCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _onSelectEngine(DbEngine eng) {
    setState(() {
      _selectedEngine = eng;
      _portCtrl.text = eng.defaultPort.toString();
      if (_nameCtrl.text.isEmpty || _nameCtrl.text.startsWith('Novo ')) {
        _nameCtrl.text = 'Novo ${eng.label}';
      }
      if (eng == DbEngine.postgres) {
        if (_userCtrl.text.isEmpty || _userCtrl.text == 'root' || _userCtrl.text == 'sa') _userCtrl.text = 'postgres';
        if (_dbCtrl.text.isEmpty) _dbCtrl.text = 'postgres';
      } else if (eng == DbEngine.mysql) {
        if (_userCtrl.text.isEmpty || _userCtrl.text == 'postgres' || _userCtrl.text == 'sa') _userCtrl.text = 'root';
        if (_dbCtrl.text.isEmpty) _dbCtrl.text = 'mysql';
      } else if (eng == DbEngine.sqlserver) {
        if (_userCtrl.text.isEmpty || _userCtrl.text == 'postgres' || _userCtrl.text == 'root') _userCtrl.text = 'sa';
        if (_dbCtrl.text.isEmpty) _dbCtrl.text = 'master';
      }
      _step = 2;
    });
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _testMessage = 'Testando conexão com o servidor...';
      _testSuccess = null;
    });

    Process? testTunnel;
    try {
      String host = _hostCtrl.text.trim();
      int port = int.tryParse(_portCtrl.text.trim()) ?? _selectedEngine.defaultPort;

      if (_useSshTunnel && _selectedSshHost.isNotEmpty) {
        final sshHost = widget.sshHosts.firstWhere((h) => h.id == _selectedSshHost);
        final (tPort, proc) = await widget.tunnelManager.openTunnel(
          sshHost: sshHost,
          remoteDbHost: host,
          remoteDbPort: port,
        );
        testTunnel = proc;
        host = '127.0.0.1';
        port = tPort;
      }

      final dummy = DbConnectionConfig(
        id: 'test',
        name: 'test',
        engine: _selectedEngine,
        environment: _selectedEnv,
        host: host,
        port: port,
        databaseName: _dbCtrl.text.trim(),
        username: _userCtrl.text.trim(),
        password: _passCtrl.text,
        ssl: _ssl,
      );

      final client = DatabaseClient.create(dummy);
      final ok = await client.testConnection();
      if (mounted) {
        setState(() {
          _testSuccess = ok;
          _testMessage = ok ? 'Conexão estabelecida com sucesso!' : 'Não foi possível conectar ao banco.';
          _isTesting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        final errStr = e.toString();
        String msg;
        if (e is SocketException || errStr.contains('SocketException') || errStr.contains('errno = 111')) {
          msg = 'Não foi possível conectar em ${_hostCtrl.text.trim()}:${_portCtrl.text.trim()} (Conexão recusada).\n\n'
                '• Verifique se o serviço do banco de dados está ativo.\n'
                '• Confirme se a porta informada está correta (no Docker, use a porta exposta no host).\n'
                '• Se o banco for local, mantenha "Túnel SSH Integrado" desativado.';
        } else {
          msg = 'Erro na conexão: $e';
        }
        setState(() {
          _testSuccess = false;
          _testMessage = msg;
          _isTesting = false;
        });
      }
    } finally {
      if (testTunnel != null) widget.tunnelManager.closeTunnel(testTunnel);
    }
  }

  void _save() {
    final id = widget.existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
    final name = _nameCtrl.text.trim().isEmpty ? 'Conexão ${_selectedEngine.label}' : _nameCtrl.text.trim();
    final host = _hostCtrl.text.trim().isEmpty ? '127.0.0.1' : _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? _selectedEngine.defaultPort;

    final config = DbConnectionConfig(
      id: id,
      name: name,
      engine: _selectedEngine,
      environment: _selectedEnv,
      host: host,
      port: port,
      databaseName: _dbCtrl.text.trim(),
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
      hasPassword: _passCtrl.text.isNotEmpty,
      useSshTunnel: _useSshTunnel,
      sshHostId: _selectedSshHost,
      ssl: _ssl,
    );

    Navigator.pop(context, config);
  }

  InputDecoration _buildInputDecoration({
    required String labelText,
    String? hintText,
    Widget? prefixIcon,
    Widget? suffixIcon,
    required bool isDark,
    required Color borderCol,
  }) {
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      isDense: true,
      filled: true,
      fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: borderCol),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: borderCol),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: _selectedEngine.brandColor, width: 1.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final dialogBg = isDark ? const Color(0xFF162032) : Colors.white;
    final borderCol = isDark ? const Color(0xFF26354D) : const Color(0xFFE2E8F0);
    final cardBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC);
    final textPrimary = isDark ? Colors.white : const Color(0xFF0F172A);
    final textSecondary = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Dialog(
      backgroundColor: dialogBg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: borderCol),
      ),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        width: 640,
        height: _step == 1 ? 460 : 660,
        child: Column(
          children: [
            // Header
            _buildDialogHeader(borderCol, textPrimary, textSecondary, isDark),
            const Divider(height: 1),

            // Content
            Expanded(
              child: _step == 1
                  ? _buildStep1SelectEngine(cardBg, borderCol, textPrimary, textSecondary, isDark)
                  : _buildStep2Form(cardBg, borderCol, textPrimary, textSecondary, isDark),
            ),
            const Divider(height: 1),

            // Footer
            _buildDialogFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildDialogHeader(Color borderCol, Color textPrimary, Color textSecondary, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      child: Row(
        children: [
          if (_step == 2 && widget.existing == null) ...[
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
              tooltip: 'Voltar para seleção de modelo',
              onPressed: () => setState(() => _step = 1),
            ),
            const SizedBox(width: 4),
          ],
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: (_step == 1 ? const Color(0xFF10B981) : _selectedEngine.brandColor).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _step == 1 ? Icons.dashboard_customize_rounded : _selectedEngine.iconData,
              color: _step == 1 ? const Color(0xFF10B981) : _selectedEngine.brandColor,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _step == 1
                      ? 'Nova Conexão - Escolha o Banco de Dados'
                      : (widget.existing == null ? 'Configurar Conexão: ${_selectedEngine.label}' : 'Editar Conexão: ${_selectedEngine.label}'),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _step == 1
                      ? 'Selecione o modelo para iniciar o cadastro com as portas e parâmetros ideais.'
                      : 'Preencha os dados de host, autenticação e túnel SSH.',
                  style: TextStyle(fontSize: 11.5, color: textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: 'Fechar',
          ),
        ],
      ),
    );
  }

  Widget _buildStep1SelectEngine(Color cardBg, Color borderCol, Color textPrimary, Color textSecondary, bool isDark) {
    final engines = [
      (
        engine: DbEngine.postgres,
        tag: 'Porta 5432',
        desc: 'Banco relacional avançado com schemas, JSON nativo e alta integridade.',
      ),
      (
        engine: DbEngine.mysql,
        tag: 'Porta 3306',
        desc: 'Compatível com MySQL 5.7, 8.x e MariaDB (autenticação nativa ou caching_sha2).',
      ),
      (
        engine: DbEngine.sqlserver,
        tag: 'Porta 1433',
        desc: 'Instâncias corporativas Microsoft SQL Server, T-SQL e protocolo TDS.',
      ),
    ];

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        ...engines.map((item) {
          final isSel = _selectedEngine == item.engine;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _onSelectEngine(item.engine),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isSel ? item.engine.brandColor.withValues(alpha: 0.12) : cardBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSel ? item.engine.brandColor : borderCol,
                    width: isSel ? 2 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: item.engine.brandColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(item.engine.iconData, color: item.engine.brandColor, size: 26),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                item.engine.label,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  color: textPrimary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: item.engine.brandColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  item.tag,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                    color: item.engine.brandColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item.desc,
                            style: TextStyle(fontSize: 12, color: textSecondary),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: item.engine.brandColor, size: 22),
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildStep2Form(Color cardBg, Color borderCol, Color textPrimary, Color textSecondary, bool isDark) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        // Name and Environment
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _nameCtrl,
                style: TextStyle(color: textPrimary),
                decoration: _buildInputDecoration(
                  labelText: 'Nome / Apelido da Conexão',
                  hintText: 'Ex: ${_selectedEngine.label} Produção',
                  prefixIcon: const Icon(Icons.label_outline_rounded, size: 18),
                  isDark: isDark,
                  borderCol: borderCol,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<DbEnvironment>(
                initialValue: _selectedEnv,
                dropdownColor: isDark ? const Color(0xFF162032) : Colors.white,
                style: TextStyle(color: textPrimary),
                decoration: _buildInputDecoration(
                  labelText: 'Ambiente',
                  prefixIcon: const Icon(Icons.shield_outlined, size: 18),
                  isDark: isDark,
                  borderCol: borderCol,
                ),
                items: DbEnvironment.values.map((env) {
                  return DropdownMenuItem(
                    value: env,
                    child: Row(
                      children: [
                        Container(width: 8, height: 8, decoration: BoxDecoration(color: env.color, shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Text(env.label, style: const TextStyle(fontSize: 12.5)),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _selectedEnv = val);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Host & Port
        Row(
          children: [
            Expanded(
              flex: 4,
              child: TextField(
                controller: _hostCtrl,
                style: TextStyle(color: textPrimary),
                decoration: _buildInputDecoration(
                  labelText: 'Host / Endereço IP',
                  hintText: 'Ex: 127.0.0.1 ou db.empresa.com',
                  prefixIcon: const Icon(Icons.dns_outlined, size: 18),
                  isDark: isDark,
                  borderCol: borderCol,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _portCtrl,
                keyboardType: TextInputType.number,
                style: TextStyle(color: textPrimary),
                decoration: _buildInputDecoration(
                  labelText: 'Porta',
                  prefixIcon: const Icon(Icons.tag_rounded, size: 18),
                  isDark: isDark,
                  borderCol: borderCol,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Database Name
        TextField(
          controller: _dbCtrl,
          style: TextStyle(color: textPrimary),
          decoration: _buildInputDecoration(
            labelText: 'Nome do Banco de Dados (Database)',
            hintText: _selectedEngine == DbEngine.postgres ? 'postgres' : (_selectedEngine == DbEngine.mysql ? 'mysql' : 'master'),
            prefixIcon: const Icon(Icons.storage_rounded, size: 18),
            isDark: isDark,
            borderCol: borderCol,
          ),
        ),
        const SizedBox(height: 14),

        // Username & Password
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _userCtrl,
                style: TextStyle(color: textPrimary),
                decoration: _buildInputDecoration(
                  labelText: 'Usuário',
                  prefixIcon: const Icon(Icons.person_outline_rounded, size: 18),
                  isDark: isDark,
                  borderCol: borderCol,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _passCtrl,
                obscureText: _obscurePassword,
                style: TextStyle(color: textPrimary),
                decoration: _buildInputDecoration(
                  labelText: 'Senha',
                  prefixIcon: const Icon(Icons.lock_outline_rounded, size: 18),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                  isDark: isDark,
                  borderCol: borderCol,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // SSL Toggle
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: _ssl,
          title: Text('Exigir Criptografia SSL / TLS', style: TextStyle(fontSize: 13, color: textPrimary)),
          onChanged: (val) => setState(() => _ssl = val ?? false),
        ),
        const SizedBox(height: 6),

        // SSH Tunnel Section (Bastion)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderCol),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.hub_rounded, size: 18, color: Color(0xFF38BDF8)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Túnel SSH Integrado (Bastion / Jump Host)',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: textPrimary)),
                        Text('Conecta ao banco seguro através de um servidor SSH do Openoia.',
                            style: TextStyle(fontSize: 11, color: textSecondary)),
                      ],
                    ),
                  ),
                  Switch(
                    value: _useSshTunnel,
                    activeThumbColor: const Color(0xFF38BDF8),
                    onChanged: (val) => setState(() => _useSshTunnel = val),
                  ),
                ],
              ),
              if (_useSshTunnel) ...[
                const SizedBox(height: 10),
                if (widget.sshHosts.isEmpty)
                  const Text('Nenhum servidor SSH cadastrado na aba "SSH & SFTP".',
                      style: TextStyle(color: Color(0xFFEF4444), fontSize: 12))
                else
                  DropdownButtonFormField<String>(
                    initialValue: _selectedSshHost.isNotEmpty && widget.sshHosts.any((h) => h.id == _selectedSshHost)
                        ? _selectedSshHost
                        : widget.sshHosts.first.id,
                    dropdownColor: isDark ? const Color(0xFF162032) : Colors.white,
                    style: TextStyle(color: textPrimary),
                    decoration: _buildInputDecoration(
                      labelText: 'Servidor SSH para o Túnel',
                      prefixIcon: const Icon(Icons.terminal_rounded, size: 18),
                      isDark: isDark,
                      borderCol: borderCol,
                    ),
                    items: widget.sshHosts.map((h) {
                      return DropdownMenuItem(
                        value: h.id,
                        child: Text('${h.name} (${h.username}@${h.address})', style: const TextStyle(fontSize: 12)),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _selectedSshHost = val);
                    },
                  ),
              ],
            ],
          ),
        ),

        // Live Test Connection Result Box
        if (_testMessage != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: (_testSuccess == true ? const Color(0xFF10B981) : const Color(0xFFEF4444)).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _testSuccess == true ? const Color(0xFF10B981) : const Color(0xFFEF4444)),
            ),
            child: Row(
              children: [
                Icon(
                  _testSuccess == true ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                  color: _testSuccess == true ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _testMessage!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _testSuccess == true ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDialogFooter() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        children: [
          if (_step == 2 && widget.existing == null)
            TextButton.icon(
              onPressed: _isTesting ? null : () => setState(() => _step = 1),
              icon: const Icon(Icons.arrow_back, size: 15),
              label: const Text('Trocar Banco'),
            ),
          const Spacer(),
          TextButton(
            onPressed: _isTesting ? null : () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          const SizedBox(width: 8),
          if (_step == 1)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _selectedEngine.brandColor,
                foregroundColor: Colors.white,
              ),
              onPressed: () => _onSelectEngine(_selectedEngine),
              icon: const Icon(Icons.arrow_forward_rounded, size: 16),
              label: Text('Configurar ${_selectedEngine.label}'),
            )
          else ...[
            OutlinedButton.icon(
              onPressed: _isTesting ? null : _testConnection,
              icon: _isTesting
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering_rounded, size: 16),
              label: const Text('Testar Conexão'),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
              ),
              onPressed: _isTesting ? null : _save,
              child: const Text('Salvar Conexão'),
            ),
          ],
        ],
      ),
    );
  }
}

List<String> splitSqlStatements(String sql) {
  final statements = <String>[];
  final current = StringBuffer();
  bool inSingleQuote = false;
  bool inDoubleQuote = false;
  bool inBacktick = false;

  for (int i = 0; i < sql.length; i++) {
    final char = sql[i];
    final prev = i > 0 ? sql[i - 1] : '';

    if (char == "'" && !inDoubleQuote && !inBacktick && prev != r'\') {
      inSingleQuote = !inSingleQuote;
    } else if (char == '"' && !inSingleQuote && !inBacktick && prev != r'\') {
      inDoubleQuote = !inDoubleQuote;
    } else if (char == '`' && !inSingleQuote && !inDoubleQuote && prev != r'\') {
      inBacktick = !inBacktick;
    }

    if (char == ';' && !inSingleQuote && !inDoubleQuote && !inBacktick) {
      final stmt = current.toString().trim();
      if (stmt.isNotEmpty) {
        statements.add(stmt);
      }
      current.clear();
    } else {
      current.write(char);
    }
  }

  final remaining = current.toString().trim();
  if (remaining.isNotEmpty) {
    statements.add(remaining);
  }

  return statements;
}

