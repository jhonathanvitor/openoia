import 'package:flutter_test/flutter_test.dart';
import 'package:openoia/db_workspace_page.dart';

void main() {
  group('SQL Multi-Statement Splitting Tests', () {
    test('Splits simple statements separated by semicolon', () {
      const sql = 'SELECT * FROM tabela1; SELECT * FROM tabela2;';
      final stmts = splitSqlStatements(sql);
      expect(stmts.length, equals(2));
      expect(stmts[0], equals('SELECT * FROM tabela1'));
      expect(stmts[1], equals('SELECT * FROM tabela2'));
    });

    test('Ignores semicolons inside single quotes and backticks', () {
      const sql = "SELECT 'hello;world' AS greeting; SELECT `col;name` FROM `tbl`;";
      final stmts = splitSqlStatements(sql);
      expect(stmts.length, equals(2));
      expect(stmts[0], equals("SELECT 'hello;world' AS greeting"));
      expect(stmts[1], equals("SELECT `col;name` FROM `tbl`"));
    });

    test('Handles statement without trailing semicolon', () {
      const sql = 'SELECT * FROM users';
      final stmts = splitSqlStatements(sql);
      expect(stmts.length, equals(1));
      expect(stmts[0], equals('SELECT * FROM users'));
    });

    test('Handles empty and whitespace-only queries', () {
      expect(splitSqlStatements(''), isEmpty);
      expect(splitSqlStatements('   ; ;  \n\t  '), isEmpty);
    });

    test('Handles multi-line script with comments and multiple queries', () {
      const sql = '''
        -- Query 1
        SELECT id, name FROM clientes WHERE status = 'ativo';

        -- Query 2
        UPDATE pedidos SET status = 'processando' WHERE id = 10;

        -- Query 3
        SELECT * FROM produtos;
      ''';
      final stmts = splitSqlStatements(sql);
      expect(stmts.length, equals(3));
      expect(stmts[0], contains('SELECT id, name FROM clientes'));
      expect(stmts[1], contains("UPDATE pedidos SET status = 'processando'"));
      expect(stmts[2], contains('SELECT * FROM produtos'));
    });
  });
}
