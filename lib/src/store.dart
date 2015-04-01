library crossdart.store;

import 'dart:async';
import 'package:crossdart/src/parsed_data.dart';
import 'package:crossdart/src/environment.dart';
import 'package:crossdart/src/entity.dart';
import 'package:crossdart/src/package.dart';
import 'package:crossdart/src/location.dart';
import 'package:crossdart/src/db_pool.dart';
import 'package:sqljocky/sqljocky.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

var _logger = new Logger("store");

Map<Type, int> _types = {
  Reference: 1,
  Declaration: 2,
  Import: 3
};

// TODO: Refactor to a class

Future<ParsedData> load(Environment environment) async {
  Set<String> handledFiles = new Set();
  Set<String> unhandledFiles = environment.package.files.map((f) => f.path).toSet();
  var parsedData = new ParsedData();
  var packagesByPath = environment.packages.fold({}, (Map<String, Package>memo, Package pkg) {
    pkg.files.forEach((f) {
      memo[f.path] = pkg;
    });
    return memo;
  });
  var packagesByName = environment.packages.fold({}, (Map<String, Package>memo, Package pkg) {
    memo["${pkg.packageInfo.name}${pkg.packageInfo.version}"] = pkg;
    return memo;
  });
  while (unhandledFiles.difference(handledFiles).isNotEmpty) {
    var filePath = unhandledFiles.difference(handledFiles).first;
    handledFiles.add(filePath);
    var package = packagesByPath[filePath];
    var location = new Location(environment.config, filePath, package);
    Results results = await queryEntity(location);
    await results.forEach((Row row) {
      Package referencePackage = packagesByName["${row.r_package_name}${row.r_package_version}"];
      var reference = new Reference(environment, p.join(referencePackage.lib, row.r_file), name: row.r_name, offset: row.r_offset, end: row.r_end, package: referencePackage);

      Package declarationPackage = packagesByName["${row.d_package_name}${row.d_package_version}"];
      Declaration declaration;
      if (row.d_type == _types[Declaration]) {
        declaration = new Declaration(environment, p.join(declarationPackage.lib, row.d_file), name: row.d_name, offset: row.d_offset, end: row.d_end, package: declarationPackage);
      } else if (row.d_type == _types[Import]) {
        declaration = new Import(environment, p.join(declarationPackage.lib, row.d_file), name: row.d_name, package: declarationPackage);
      }

      parsedData.references[reference] = declaration;

      if (parsedData.declarations[declaration] == null) {
        parsedData.declarations[declaration] = new Set();
      }
      parsedData.declarations[declaration].add(reference);

      if (parsedData.files[reference.location.file] == null) {
        parsedData.files[reference.location.file] = new Set();
      }
      parsedData.files[reference.location.file].add(reference);

      if (parsedData.files[declaration.location.file] == null) {
        parsedData.files[declaration.location.file] = new Set();
      }
      parsedData.files[declaration.location.file].add(declaration);
    });

    unhandledFiles.addAll(parsedData.files.keys);
  }
  return parsedData;
}

Future<Results> queryEntity(Location location) {
  return dbPool.query("""
    SELECT r.id AS 'r_id', r.name AS 'r_name', r.offset AS 'r_offset', r.end AS 'r_end', r.file AS 'r_file', r.package_name AS 'r_package_name', r.package_version AS 'r_package_version',
           d.id AS 'd_id', d.type AS 'd_type', d.name AS 'd_name', d.offset AS 'd_offset', d.end AS 'd_end', d.file AS 'd_file', d.package_name AS 'd_package_name', d.package_version AS 'd_package_version'
    FROM entities AS r
    INNER JOIN entities AS d ON r.declaration_id = d.id
    WHERE r.type = ${_types[Reference]} AND r.file = '${location.path}' AND r.package_name = '${location.package.packageInfo.name}' AND r.package_version = '${location.package.packageInfo.version}'
  """);
}

Future store(Environment environment, ParsedData parsedData) async {
  return dbPool.prepare("""
    INSERT IGNORE INTO entities (declaration_id, type, name, offset, end, file, package_name, package_version)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  """).then((query) async {
    var files = [];
    _logger.info("Preparing files");
    parsedData.files.forEach((filePath, entities) {
      files.add([filePath, entities]);
    });

    _logger.info("Storing declarations");
    var idsByDeclarationsList = await Future.wait(files.map((tuple) async {
      var filePath = tuple[0];
      var entities = tuple[1];
      var filteredEntities = entities.where((e) => e is Declaration);
      return await _storeDeclarations(environment, query, filePath, filteredEntities);
    }));

    _logger.info("Making idsByDeclaration map");
    var idsByDeclarations = idsByDeclarationsList.fold({}, (memo, map) {
      memo.addAll(map);
      return memo;
    });

    _logger.info("Storing references");
    return await Future.wait(files.map((tuple) {
      var filePath = tuple[0];
      var entities = tuple[1];
      var filteredEntities = entities.where((e) => e is Reference);
      return _storeReferences(environment, parsedData, query, filePath, filteredEntities, idsByDeclarations);
    }));
  });
}

List _buildValue(Entity entity, Location location, [int declarationId]) {
  return [
      declarationId,
      _types[entity.runtimeType],
      entity.name,
      entity.offset,
      entity.end,
      location.path,
      location.package.name,
      location.package.version.toString()];
}

Future<Map<Declaration, int>> _storeDeclarations(Environment environment, Query query, String filePath, Iterable<Declaration> declarations) async {
  var location = new Location(environment.config, filePath, Package.fromFilePath(environment, filePath));
  var idAndDeclaration = await Future.wait(declarations.map((declaration) async {
    var value = _buildValue(declaration, location);
    Results result = await query.execute(value);
    var id = result.insertId;
    return [declaration, id];
  }));
  return idAndDeclaration.fold({}, (memo, values) {
    memo[values[0]] = values[1];
    return memo;
  });
}

Future _storeReferences(Environment environment, ParsedData parsedData, Query query, String filePath, Iterable<Reference> references, [Map<Declaration, int> idsByDeclarations]) {
  var location = new Location(environment.config, filePath, Package.fromFilePath(environment, filePath));
  var values = references.map((reference) {
    var declaration = parsedData.references[reference];
    var declarationId = idsByDeclarations[declaration];
    return _buildValue(reference, location, declarationId);
  }).toList();
  return Future.wait(values.map((value) {
    return query.execute(value);
  }));
}

Future storeError(PackageInfo packageInfo, Object error, StackTrace stackTrace) {
  return dbPool.prepareExecute(
      "INSERT IGNORE INTO errors (package_name, package_version, error) VALUES (?, ?, ?)",
      [packageInfo.name, packageInfo.version.toString(), "${error}\n${stackTrace}"]);
}