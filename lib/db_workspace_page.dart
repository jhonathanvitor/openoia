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

class QueryTabItem extends DbWorkspaceTab {
  final TextEditingController sqlController;
  DbQueryResult? result;
  bool isRunning;
  int pageIndex;
  int pageSize;
  String tableSearchFilter;

  QueryTabItem({
    required super.id,
    required super.title,
    String initialSql = '',
  })  : sqlController = TextEditingController(text: initialSql),
        isRunning = false,
        pageIndex = 0,
        pageSize = 50,
        tableSearchFilter = '',
        super(icon: Icons.code_rounded);
}

class TableTabItem extends DbWorkspaceTab {
  final String schema;
  final String tableName;
  int subTabIndex; // 0: Dados, 1: Estrutura, 2: DDL
  DbQueryResult? dataResult;
  List<TableColumnMetadata>? columns;
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

  // Metadata tree
  List<String> _schemas = [];
  String _selectedSchema = '';
  List<String> _tables = [];
  String _tableSearchQuery = '';
  final Map<String, List<TableColumnMetadata>> _tableColumnsCache = {};
  final Set<String> _expandedTables = {};

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
    _addNewQueryTab();
  }

  @override
  void dispose() {
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

  void _addNewQueryTab({String initialSql = ''}) {
    final title = 'Query $_queryCounter.sql';
    _queryCounter++;
    final tab = QueryTabItem(
      id: 'query_${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      initialSql: initialSql.isEmpty ? '-- Escreva sua consulta SQL e pressione Ctrl+Enter ou clique em Executar\n' : initialSql,
    );
    setState(() {
      _tabs.add(tab);
      _activeTabIndex = _tabs.length - 1;
    });
  }

  void _closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    setState(() {
      _tabs.removeAt(index);
      if (_tabs.isEmpty) {
        _addNewQueryTab();
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

      // Load schemas and tables
      _schemas = await client.listSchemas();
      if (_schemas.isEmpty) _schemas = ['public'];
      _selectedSchema = _schemas.contains('public') ? 'public' : _schemas.first;
      await _refreshTables();

      if (mounted) {
        setState(() => _isConnecting = false);
      }
    } catch (e) {
      await _disconnectActive();
      if (mounted) {
        setState(() => _isConnecting = false);
        _showErrorDialog('Falha na Conexão', e.toString());
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
        _tables.clear();
        _tableColumnsCache.clear();
        _expandedTables.clear();
      });
    }
  }

  Future<void> _refreshTables() async {
    if (_activeClient == null) return;
    try {
      final t = await _activeClient!.listTables(schema: _selectedSchema);
      if (mounted) {
        setState(() => _tables = t);
      }
    } catch (_) {}
  }

  Future<void> _openTableTab(String table) async {
    final existingIdx = _tabs.indexWhere(
      (t) => t is TableTabItem && t.tableName == table && t.schema == _selectedSchema,
    );
    if (existingIdx >= 0) {
      setState(() => _activeTabIndex = existingIdx);
      return;
    }

    final tab = TableTabItem(
      id: 'table_${_selectedSchema}_$table',
      schema: _selectedSchema,
      tableName: table,
    );

    setState(() {
      _tabs.add(tab);
      _activeTabIndex = _tabs.length - 1;
    });

    await _loadTableData(tab);
  }

  Future<void> _loadTableData(TableTabItem tab) async {
    if (_activeClient == null) return;
    setState(() => tab.isLoading = true);

    try {
      final query = 'SELECT * FROM ${_formatTableName(tab.schema, tab.tableName)} LIMIT 200;';
      final res = await _activeClient!.executeQuery(query);
      final cols = await _activeClient!.getTableColumns(tab.tableName, schema: tab.schema);
      final ddl = await _activeClient!.getTableDdl(tab.tableName, schema: tab.schema);

      if (mounted) {
        setState(() {
          tab.dataResult = res;
          tab.columns = cols;
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

  String _formatTableName(String schema, String table) {
    if (_activeConnection?.engine == DbEngine.mysql) {
      return '`$table`';
    } else if (_activeConnection?.engine == DbEngine.sqlserver) {
      return '[$schema].[$table]';
    }
    return '"$schema"."$table"';
  }

  Future<void> _executeQuery(QueryTabItem tab) async {
    if (_activeClient == null) {
      _showErrorDialog('Sem Conexão', 'Conecte-se a um banco de dados antes de executar consultas.');
      return;
    }

    final sql = tab.sqlController.text.trim();
    if (sql.isEmpty) return;

    // Safety check for production environment
    if (_activeConnection?.environment == DbEnvironment.production) {
      final upper = sql.toUpperCase();
      if (upper.contains('DROP ') || upper.contains('TRUNCATE ') || upper.contains('DELETE ') || upper.contains('UPDATE ')) {
        final confirm = await _showProductionWarningDialog(sql);
        if (!confirm) return;
      }
    }

    setState(() => tab.isRunning = true);
    final res = await _activeClient!.executeQuery(sql, maxRows: 500);

    if (mounted) {
      setState(() {
        tab.result = res;
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
            child: _activeConnection == null || _tables.isEmpty
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
    final filteredTables = _tableSearchQuery.isEmpty
        ? _tables
        : _tables.where((t) => t.toLowerCase().contains(_tableSearchQuery.toLowerCase())).toList();

    return Column(
      children: [
        // Schemas Selector & Table Search
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            children: [
              if (_schemas.length > 1)
                DropdownButtonFormField<String>(
                  initialValue: _selectedSchema,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'Esquema (Schema)',
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    border: OutlineInputBorder(),
                  ),
                  items: _schemas.map((s) => DropdownMenuItem(value: s, child: Text(s, style: const TextStyle(fontSize: 12)))).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _selectedSchema = val);
                      _refreshTables();
                    }
                  },
                ),
              const SizedBox(height: 6),
              TextField(
                decoration: InputDecoration(
                  hintText: 'Buscar tabelas (${filteredTables.length})...',
                  prefixIcon: const Icon(Icons.search, size: 16),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                style: const TextStyle(fontSize: 12),
                onChanged: (val) => setState(() => _tableSearchQuery = val),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Tables List
        Expanded(
          child: ListView.builder(
            itemCount: filteredTables.length,
            itemBuilder: (ctx, i) {
              final table = filteredTables[i];
              final isExpanded = _expandedTables.contains(table);
              final cachedCols = _tableColumnsCache[table];

              return Column(
                children: [
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                    leading: const Icon(Icons.table_chart_rounded, size: 16, color: Color(0xFF38BDF8)),
                    title: Text(table, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(isExpanded ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_right_rounded, size: 18),
                          onPressed: () async {
                            setState(() {
                              if (isExpanded) {
                                _expandedTables.remove(table);
                              } else {
                                _expandedTables.add(table);
                              }
                            });
                            if (!isExpanded && cachedCols == null && _activeClient != null) {
                              final cols = await _activeClient!.getTableColumns(table, schema: _selectedSchema);
                              setState(() => _tableColumnsCache[table] = cols);
                            }
                          },
                        ),
                      ],
                    ),
                    onTap: () => _openTableTab(table),
                  ),
                  if (isExpanded)
                    Container(
                      padding: const EdgeInsets.only(left: 32, right: 10, bottom: 6),
                      child: cachedCols == null
                          ? const SizedBox(height: 20, child: LinearProgressIndicator())
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: cachedCols.map((c) {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 2),
                                  child: Row(
                                    children: [
                                      Icon(
                                        c.isPrimaryKey ? Icons.key_rounded : Icons.lens_rounded,
                                        size: c.isPrimaryKey ? 12 : 6,
                                        color: c.isPrimaryKey ? const Color(0xFFF59E0B) : Colors.grey,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          c.name,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: c.isPrimaryKey ? FontWeight.bold : FontWeight.normal,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        c.dataType,
                                        style: const TextStyle(fontSize: 10.5, color: Colors.grey, fontFamily: 'monospace'),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildWorkspace(Color cardBg, Color borderCol, bool isDark) {
    if (_tabs.isEmpty) {
      return const Center(child: Text('Nenhuma aba aberta.'));
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
    return Column(
      children: [
        // SQL Editor Panel
        Expanded(
          flex: 4,
          child: Container(
            color: isDark ? const Color(0xFF0F172A) : Colors.white,
            padding: const EdgeInsets.all(12),
            child: Column(
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
                    const SizedBox(width: 12),
                    if (tab.result != null) ...[
                      Chip(
                        label: Text('⏱️ ${tab.result!.executionTimeMs} ms', style: const TextStyle(fontSize: 11)),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                      const SizedBox(width: 8),
                      Chip(
                        label: Text('📊 ${tab.result!.isSelect ? "${tab.result!.rows.length} linhas" : "${tab.result!.affectedRows} afetadas"}',
                            style: const TextStyle(fontSize: 11)),
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
                const SizedBox(height: 8),
                // Text Area with Shortcuts
                Expanded(
                  child: Shortcuts(
                    shortcuts: {
                      LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.enter): const ActivateIntent(),
                    },
                    child: Actions(
                      actions: {
                        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _executeQuery(tab)),
                      },
                      child: TextField(
                        controller: tab.sqlController,
                        maxLines: null,
                        expands: true,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.4,
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Escreva sua consulta SQL aqui...',
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, thickness: 1, color: borderCol),

        // Results Panel
        Expanded(
          flex: 6,
          child: _buildResultsGrid(tab.result, tab.pageIndex, tab.pageSize, (idx) {
            setState(() => tab.pageIndex = idx);
          }, isDark),
        ),
      ],
    );
  }

  Widget _buildTableTabContent(TableTabItem tab, bool isDark, Color borderCol) {
    return Column(
      children: [
        // Sub-tabs switcher (DBeaver style: Dados | Estrutura | DDL)
        Container(
          color: isDark ? const Color(0xFF162032) : Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('📊 Dados'), icon: Icon(Icons.table_rows_rounded, size: 16)),
                  ButtonSegment(value: 1, label: Text('⚙️ Estrutura'), icon: Icon(Icons.schema_rounded, size: 16)),
                  ButtonSegment(value: 2, label: Text('📜 DDL / SQL'), icon: Icon(Icons.code_rounded, size: 16)),
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
                    // Sub-tab 0: Dados
                    _buildResultsGrid(tab.dataResult, tab.pageIndex, tab.pageSize, (idx) {
                      setState(() => tab.pageIndex = idx);
                    }, isDark),

                    // Sub-tab 1: Estrutura (Colunas, tipos, PK)
                    _buildStructureGrid(tab.columns, isDark),

                    // Sub-tab 2: DDL
                    _buildDdlView(tab.ddl, isDark),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildStructureGrid(List<TableColumnMetadata>? columns, bool isDark) {
    if (columns == null || columns.isEmpty) {
      return const Center(child: Text('Nenhuma coluna disponível.'));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: DataTable(
        columns: const [
          DataColumn(label: Text('Nome da Coluna', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Tipo de Dado', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Nullable', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Chave Primária', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Valor Padrão', style: TextStyle(fontWeight: FontWeight.bold))),
        ],
        rows: columns.map((c) {
          return DataRow(
            cells: [
              DataCell(
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (c.isPrimaryKey) ...[
                      const Icon(Icons.key_rounded, size: 14, color: Color(0xFFF59E0B)),
                      const SizedBox(width: 6),
                    ],
                    Text(c.name, style: TextStyle(fontWeight: c.isPrimaryKey ? FontWeight.bold : FontWeight.normal)),
                  ],
                ),
              ),
              DataCell(Text(c.dataType, style: const TextStyle(fontFamily: 'monospace'))),
              DataCell(Text(c.isNullable ? 'SIM' : 'NÃO', style: TextStyle(color: c.isNullable ? Colors.grey : const Color(0xFFEF4444)))),
              DataCell(Text(c.isPrimaryKey ? '🔑 PK' : '-')),
              DataCell(Text(c.defaultValue ?? '-')),
            ],
          );
        }).toList(),
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

  Widget _buildResultsGrid(
    DbQueryResult? result,
    int pageIndex,
    int pageSize,
    Function(int) onPageChange,
    bool isDark,
  ) {
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

    return Column(
      children: [
        // Export Toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: isDark ? const Color(0xFF162032) : Colors.white,
          child: Row(
            children: [
              Text('$totalRows registros', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
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

        // Grid Table
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 36,
                dataRowMinHeight: 32,
                dataRowMaxHeight: 36,
                columns: result.columns.map((col) {
                  return DataColumn(
                    label: Text(col, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  );
                }).toList(),
                rows: displayedRows.map((row) {
                  return DataRow(
                    cells: row.map((cell) {
                      final text = cell?.toString() ?? 'NULL';
                      final isNull = cell == null;
                      return DataCell(
                        SelectableText(
                          text,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontFamily: 'monospace',
                            color: isNull ? Colors.grey : null,
                            fontStyle: isNull ? FontStyle.italic : FontStyle.normal,
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
        const Divider(height: 1),

        // Pagination Bar
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          color: isDark ? const Color(0xFF162032) : Colors.white,
          child: Row(
            children: [
              Text('Exibindo ${startIndex + 1} - $endIndex de $totalRows', style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.first_page_rounded, size: 18),
                onPressed: pageIndex > 0 ? () => onPageChange(0) : null,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_left_rounded, size: 18),
                onPressed: pageIndex > 0 ? () => onPageChange(pageIndex - 1) : null,
              ),
              Text('Página ${pageIndex + 1}', style: const TextStyle(fontSize: 11.5)),
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
        setState(() {
          _testSuccess = false;
          _testMessage = 'Erro na conexão: $e';
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
