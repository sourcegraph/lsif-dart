library crossdart.package;

import 'dart:io';
import 'dart:async';
import 'package:crossdart/src/db_pool.dart';
import 'package:crossdart/src/util/map.dart';
import 'package:crossdart/src/config.dart';
import 'package:crossdart/src/environment.dart';
import 'package:crossdart/src/version.dart';
import 'package:crossdart/src/entity.dart';
import 'package:crossdart/src/package_info.dart';
import 'package:crossdart/src/util.dart';
import 'package:crossdart/src/store.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

//TODO: Add package type
//enum PackageType { IO, HTML }

abstract class Package {
  final PackageInfo packageInfo;
  //final PackageType type;
  final String description;
  final Config config;
  final Iterable<String> paths;

  Package(this.config, this.packageInfo, this.description, this.paths);

  static Package fromAbsolutePath(Environment environment, String filePath) {
    return environment.packagesByFiles[filePath];
  }

  String get name => packageInfo.name;
  Version get version => packageInfo.version;
  int get id => packageInfo.id;
  PackageSource get source => packageInfo.source;

  String get lib;
  Iterable<Package> dependencies(Environment environment);

  Iterable<String> get absolutePaths {
    return paths.map(absolutePath);
  }

  String absolutePath(String relativePath) {
    return p.join(lib, relativePath);
  }

  String get pubUrl {
    return "https://pub.dartlang.org/packages/${name}";
  }

  String relativePath(String absolutePath) {
    return absolutePath.replaceFirst(lib, "").replaceFirst(new RegExp(r"^/"), "");
  }

  String toString() {
    return "<Package ${toMap()}>";
  }

  Map<String, Object> toMap() {
    return {
        "name": name,
        "version": version,
        "id": id,
        "source": source,
        "description": description,
        "paths": paths};
  }

  int get hashCode => hash([packageInfo]);
  bool operator ==(other) => other is Package && packageInfo == other.packageInfo;
}


class Sdk extends Package {
  Sdk(
      Config config,
      PackageInfo packageInfo,
      String description,
      Iterable<String> paths) :
      super(config, packageInfo, description, paths);

  Iterable<Package> _dependencies;
  Iterable<Package> dependencies(Environment environment) {
    if (_dependencies == null) {
      var names = ["barback", "stack_trace"];
      _dependencies = environment.customPackages.where((cp) => names.contains(cp.packageInfo.name));
    }
    return _dependencies;
  }

  String get lib {
    if (packageInfo.version.toString() == config.sdk.sdkVersion) {
      return p.join(config.sdkPath, "lib");
    } else {
      return p.join(config.sdkPackagesRoot, packageInfo.dirname, "lib");
    }
  }
}

class Project extends Package {
  Project(
      Config config,
      PackageInfo packageInfo,
      String description,
      Iterable<String> paths) :
      super(config, packageInfo, description, paths);

  Iterable<Package> dependencies(Environment environment) {
    return environment.customPackages.where((cp) => ["barback", "stack_trace"].contains(cp.packageInfo.name));
  }

  String get _root => config.projectPath;
  String get lib => p.join(_root, "lib");
}


class CustomPackage extends Package {
  CustomPackage(
      Config config,
      PackageInfo packageInfo,
      String description,
      Iterable<String> paths) :
      super(config, packageInfo, description, paths);

  String get _packagesRoot {
    if (source == PackageSource.GIT) {
      return config.gitPackagesRoot;
    } else {
      return config.hostedPackagesRoot;
    }
  }

  String get _root => p.join(_packagesRoot, "${name}-${version}");

  String get lib => p.join(_root, "lib");

  List<Package> _dependencies;
  Iterable<Package> dependencies(Environment environment) {
    if (_dependencies == null) {
      _dependencies = [environment.sdk];
      var pubspecPath = p.join(_root, "pubspec.yaml");
      var file = new File(pubspecPath);
      if (file.existsSync()) {
        var yaml = loadYaml(file.readAsStringSync());
        var dependencies = yaml["dependencies"];
        if (dependencies != null) {
          dependencies.forEach((name, version) {
            var package = environment.customPackages.firstWhere((cp) => cp.packageInfo.name == name, orElse: () => null);
            if (package != null) {
              _dependencies.add(package);
            }
          });
        }
      }
    }
    return _dependencies;
  }
}

Future<Package> buildFromFileSystem(Config config, PackageInfo packageInfo) {
  if (packageInfo.isSdk) {
    return buildSdkFromFileSystem(config, packageInfo);
  } else {
    return buildCustomPackageFromFileSystem(config, packageInfo);
  }
}

Future<Package> buildFromDatabase(Config config, PackageInfo packageInfo) async {
  var result = await (await dbPool(config).query("""
      SELECT id, source_type, description FROM packages WHERE name = '${packageInfo.name}' AND version = '${packageInfo.version}'  
  """)).toList();
  var row = result.isNotEmpty ? result.first : null;
  if (row != null) {
    var paths = (await (await dbPool(config).query("""
        SELECT DISTINCT path FROM entities WHERE package_id = ${row.id} AND type = ${entityTypeIds[Reference]}  
    """)).toList()).map((r) => r.path);
    var source = key(packageSourceIds, row.source_type);
    if (packageInfo.isSdk) {
      return new Sdk(config, packageInfo.update(id: row.id, source: key(packageSourceIds, row.source_type)), null, paths);
    } else {
      return new CustomPackage(config, packageInfo.update(id: row.id, source: source), null, paths);
    }
  } else {
    return null;
  }
}

Future<Sdk> buildSdkFromFileSystem(Config config, PackageInfo packageInfo) async {
  String lib;
  if (packageInfo.version == config.sdk.sdkVersion) {
    lib = p.join(config.sdkPath, "lib");
  } else {
    lib = p.join(config.sdkPackagesRoot, packageInfo.dirname, "lib");
  }
  var source = PackageSource.SDK;

  var id = packageInfo.id;
  if (config.isDbUsed && id == null) {
    var transaction = await dbPool(config).startTransaction(consistent: true);
    id = await getPackageId(config, packageInfo);
    if (id == null) {
      id = await storePackage(config, packageInfo, source, null);
    }
    if (id == 0) {
      id = await getPackageId(config, packageInfo);
    }
    transaction.commit();
  }
  var paths = new Directory(lib).listSync(recursive: true).where((f) => f is File && f.path.endsWith(".dart")).map((file) {
    return file.path.replaceAll(lib, "").replaceFirst(new RegExp(r"^/"), "");
  });

  return new Sdk(config, packageInfo.update(id: id, source: source), null, paths);
}

Project buildProjectFromFileSystem(Config config) {
  var lib = p.join(config.projectPath, "lib");

  var paths = new Directory(lib).listSync(recursive: true).where((f) => f is File && f.path.endsWith(".dart")).map((file) {
    return file.path.replaceAll(lib, "").replaceFirst(new RegExp(r"^/"), "");
  });

  return new Project(config, new PackageInfo("project", new Version("")), null, paths);
}


Future<CustomPackage> buildCustomPackageFromFileSystem(Config config, PackageInfo packageInfo) async {
  Directory getDirectory() {
    var directory = new Directory(config.hostedPackagesRoot).listSync().firstWhere((entity) {
      return p.basename(entity.path).toLowerCase() == "${packageInfo.name}-${packageInfo.version}".toLowerCase()
          || p.basename(entity.path).replaceAll("+", "-").toLowerCase() == "${packageInfo.name}-${packageInfo.version}".toLowerCase();
    }, orElse: () => null);
    if (directory == null) {
       directory = new Directory(config.gitPackagesRoot).listSync().firstWhere((entity) {
        return p.basename(entity.path).toLowerCase() == "${packageInfo.name}-${packageInfo.version}".toLowerCase()
           || p.basename(entity.path).replaceAll("+", "-").toLowerCase() == "${packageInfo.name}-${packageInfo.version}".toLowerCase();
      }, orElse: () => null);
    }
    return directory;
  }

  var root = getDirectory();
  if (root == null) {
    print(config.hostedPackagesRoot);
    print(packageInfo);
  }
  root = root.resolveSymbolicLinksSync();
  var lib = p.join(root, "lib");

  YamlNode getPubspec() {
    var pubspecPath = p.join(root, "pubspec.yaml");
    var file = new File(pubspecPath);
    if (file.existsSync()) {
      return loadYaml(file.readAsStringSync());
    } else {
      return null;
    }
  }

  var source;
  if (lib.contains("/git/")) {
    source = PackageSource.GIT;
  } else {
    source = PackageSource.HOSTED;
  }
  var paths = new Directory(lib).listSync(recursive: true).where((f) => f is File && f.path.endsWith(".dart")).map((file) {
    return file.path.replaceAll(lib, "").replaceFirst(new RegExp(r"^/"), "");
  });

  var pubspec = getPubspec();
  int id = packageInfo.id;
  if (config.isDbUsed && id == null) {
    var transaction = await dbPool(config).startTransaction(consistent: true);
    id = await getPackageId(config, packageInfo);
    if (id == null) {
      id = await storePackage(config, packageInfo, source, pubspec["description"]);
    }
    if (id == 0) {
      id = await getPackageId(config, packageInfo);
    }
    transaction.commit();
  }

  return new CustomPackage(config, packageInfo.update(id: id, source: source), pubspec["description"], paths);
}
