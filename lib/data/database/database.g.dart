// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class Folders extends Table with TableInfo<Folders, Folder> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  Folders(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY NOT NULL',
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _iconMeta = const VerificationMeta('icon');
  late final GeneratedColumn<String> icon = GeneratedColumn<String>(
    'icon',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'DEFAULT \'folder\'',
    defaultValue: const CustomExpression('\'folder\''),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [id, name, icon, createdAt, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'folders';
  @override
  VerificationContext validateIntegrity(
    Insertable<Folder> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('icon')) {
      context.handle(
        _iconMeta,
        icon.isAcceptableOrUnknown(data['icon']!, _iconMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Folder map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Folder(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      icon: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}icon'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  Folders createAlias(String alias) {
    return Folders(attachedDatabase, alias);
  }

  @override
  bool get dontWriteConstraints => true;
}

class Folder extends DataClass implements Insertable<Folder> {
  final String id;
  final String name;
  final String? icon;
  final int createdAt;
  final int updatedAt;
  const Folder({
    required this.id,
    required this.name,
    this.icon,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || icon != null) {
      map['icon'] = Variable<String>(icon);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  FoldersCompanion toCompanion(bool nullToAbsent) {
    return FoldersCompanion(
      id: Value(id),
      name: Value(name),
      icon: icon == null && nullToAbsent ? const Value.absent() : Value(icon),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory Folder.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Folder(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      icon: serializer.fromJson<String?>(json['icon']),
      createdAt: serializer.fromJson<int>(json['created_at']),
      updatedAt: serializer.fromJson<int>(json['updated_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'icon': serializer.toJson<String?>(icon),
      'created_at': serializer.toJson<int>(createdAt),
      'updated_at': serializer.toJson<int>(updatedAt),
    };
  }

  Folder copyWith({
    String? id,
    String? name,
    Value<String?> icon = const Value.absent(),
    int? createdAt,
    int? updatedAt,
  }) => Folder(
    id: id ?? this.id,
    name: name ?? this.name,
    icon: icon.present ? icon.value : this.icon,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  Folder copyWithCompanion(FoldersCompanion data) {
    return Folder(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      icon: data.icon.present ? data.icon.value : this.icon,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Folder(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('icon: $icon, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, icon, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Folder &&
          other.id == this.id &&
          other.name == this.name &&
          other.icon == this.icon &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class FoldersCompanion extends UpdateCompanion<Folder> {
  final Value<String> id;
  final Value<String> name;
  final Value<String?> icon;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const FoldersCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.icon = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FoldersCompanion.insert({
    required String id,
    required String name,
    this.icon = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<Folder> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? icon,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (icon != null) 'icon': icon,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FoldersCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String?>? icon,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return FoldersCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (icon.present) {
      map['icon'] = Variable<String>(icon.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FoldersCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('icon: $icon, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class PasswordEntries extends Table
    with TableInfo<PasswordEntries, PasswordEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  PasswordEntries(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY NOT NULL',
  );
  static const VerificationMeta _folderIdMeta = const VerificationMeta(
    'folderId',
  );
  late final GeneratedColumn<String> folderId = GeneratedColumn<String>(
    'folder_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'login\'',
    defaultValue: const CustomExpression('\'login\''),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
    'url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'\'',
    defaultValue: const CustomExpression('\'\''),
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'\'',
    defaultValue: const CustomExpression('\'\''),
  );
  static const VerificationMeta _passwordEncryptedMeta = const VerificationMeta(
    'passwordEncrypted',
  );
  late final GeneratedColumn<String> passwordEncrypted =
      GeneratedColumn<String>(
        'password_encrypted',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
        $customConstraints: 'NOT NULL',
      );
  static const VerificationMeta _notesEncryptedMeta = const VerificationMeta(
    'notesEncrypted',
  );
  late final GeneratedColumn<String> notesEncrypted = GeneratedColumn<String>(
    'notes_encrypted',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'DEFAULT \'\'',
    defaultValue: const CustomExpression('\'\''),
  );
  static const VerificationMeta _totpSecretEncryptedMeta =
      const VerificationMeta('totpSecretEncrypted');
  late final GeneratedColumn<String> totpSecretEncrypted =
      GeneratedColumn<String>(
        'totp_secret_encrypted',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        $customConstraints: 'DEFAULT \'\'',
        defaultValue: const CustomExpression('\'\''),
      );
  static const VerificationMeta _dataEncryptedMeta = const VerificationMeta(
    'dataEncrypted',
  );
  late final GeneratedColumn<String> dataEncrypted = GeneratedColumn<String>(
    'data_encrypted',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT \'\'',
    defaultValue: const CustomExpression('\'\''),
  );
  static const VerificationMeta _isFavoriteMeta = const VerificationMeta(
    'isFavorite',
  );
  late final GeneratedColumn<bool> isFavorite = GeneratedColumn<bool>(
    'is_favorite',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL DEFAULT FALSE',
    defaultValue: const CustomExpression('FALSE'),
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    folderId,
    type,
    name,
    url,
    username,
    passwordEncrypted,
    notesEncrypted,
    totpSecretEncrypted,
    dataEncrypted,
    isFavorite,
    deletedAt,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'password_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<PasswordEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('folder_id')) {
      context.handle(
        _folderIdMeta,
        folderId.isAcceptableOrUnknown(data['folder_id']!, _folderIdMeta),
      );
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('url')) {
      context.handle(
        _urlMeta,
        url.isAcceptableOrUnknown(data['url']!, _urlMeta),
      );
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    }
    if (data.containsKey('password_encrypted')) {
      context.handle(
        _passwordEncryptedMeta,
        passwordEncrypted.isAcceptableOrUnknown(
          data['password_encrypted']!,
          _passwordEncryptedMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_passwordEncryptedMeta);
    }
    if (data.containsKey('notes_encrypted')) {
      context.handle(
        _notesEncryptedMeta,
        notesEncrypted.isAcceptableOrUnknown(
          data['notes_encrypted']!,
          _notesEncryptedMeta,
        ),
      );
    }
    if (data.containsKey('totp_secret_encrypted')) {
      context.handle(
        _totpSecretEncryptedMeta,
        totpSecretEncrypted.isAcceptableOrUnknown(
          data['totp_secret_encrypted']!,
          _totpSecretEncryptedMeta,
        ),
      );
    }
    if (data.containsKey('data_encrypted')) {
      context.handle(
        _dataEncryptedMeta,
        dataEncrypted.isAcceptableOrUnknown(
          data['data_encrypted']!,
          _dataEncryptedMeta,
        ),
      );
    }
    if (data.containsKey('is_favorite')) {
      context.handle(
        _isFavoriteMeta,
        isFavorite.isAcceptableOrUnknown(data['is_favorite']!, _isFavoriteMeta),
      );
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PasswordEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PasswordEntry(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      folderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}folder_id'],
      ),
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      url: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}url'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      passwordEncrypted: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}password_encrypted'],
      )!,
      notesEncrypted: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes_encrypted'],
      ),
      totpSecretEncrypted: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}totp_secret_encrypted'],
      ),
      dataEncrypted: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}data_encrypted'],
      )!,
      isFavorite: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_favorite'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  PasswordEntries createAlias(String alias) {
    return PasswordEntries(attachedDatabase, alias);
  }

  @override
  List<String> get customConstraints => const [
    'FOREIGN KEY(folder_id)REFERENCES folders(id)ON DELETE SET NULL',
  ];
  @override
  bool get dontWriteConstraints => true;
}

class PasswordEntry extends DataClass implements Insertable<PasswordEntry> {
  final String id;
  final String? folderId;
  final String type;
  final String name;
  final String url;
  final String username;
  final String passwordEncrypted;
  final String? notesEncrypted;
  final String? totpSecretEncrypted;
  final String dataEncrypted;
  final bool isFavorite;

  /// 回收站（schema 5，3.1.0）：NULL = 正常；非 NULL = 删除时间（毫秒）。
  /// 「删除」只打这个标记，行与密文一个字节都不动；「恢复」就是置回 NULL。
  /// 主密码轮换会照样遍历回收站行（getAllEntries），否则那些密文会留在旧钥匙上。
  final int? deletedAt;
  final int createdAt;
  final int updatedAt;
  const PasswordEntry({
    required this.id,
    this.folderId,
    required this.type,
    required this.name,
    required this.url,
    required this.username,
    required this.passwordEncrypted,
    this.notesEncrypted,
    this.totpSecretEncrypted,
    required this.dataEncrypted,
    required this.isFavorite,
    this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || folderId != null) {
      map['folder_id'] = Variable<String>(folderId);
    }
    map['type'] = Variable<String>(type);
    map['name'] = Variable<String>(name);
    map['url'] = Variable<String>(url);
    map['username'] = Variable<String>(username);
    map['password_encrypted'] = Variable<String>(passwordEncrypted);
    if (!nullToAbsent || notesEncrypted != null) {
      map['notes_encrypted'] = Variable<String>(notesEncrypted);
    }
    if (!nullToAbsent || totpSecretEncrypted != null) {
      map['totp_secret_encrypted'] = Variable<String>(totpSecretEncrypted);
    }
    map['data_encrypted'] = Variable<String>(dataEncrypted);
    map['is_favorite'] = Variable<bool>(isFavorite);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  PasswordEntriesCompanion toCompanion(bool nullToAbsent) {
    return PasswordEntriesCompanion(
      id: Value(id),
      folderId: folderId == null && nullToAbsent
          ? const Value.absent()
          : Value(folderId),
      type: Value(type),
      name: Value(name),
      url: Value(url),
      username: Value(username),
      passwordEncrypted: Value(passwordEncrypted),
      notesEncrypted: notesEncrypted == null && nullToAbsent
          ? const Value.absent()
          : Value(notesEncrypted),
      totpSecretEncrypted: totpSecretEncrypted == null && nullToAbsent
          ? const Value.absent()
          : Value(totpSecretEncrypted),
      dataEncrypted: Value(dataEncrypted),
      isFavorite: Value(isFavorite),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory PasswordEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PasswordEntry(
      id: serializer.fromJson<String>(json['id']),
      folderId: serializer.fromJson<String?>(json['folder_id']),
      type: serializer.fromJson<String>(json['type']),
      name: serializer.fromJson<String>(json['name']),
      url: serializer.fromJson<String>(json['url']),
      username: serializer.fromJson<String>(json['username']),
      passwordEncrypted: serializer.fromJson<String>(
        json['password_encrypted'],
      ),
      notesEncrypted: serializer.fromJson<String?>(json['notes_encrypted']),
      totpSecretEncrypted: serializer.fromJson<String?>(
        json['totp_secret_encrypted'],
      ),
      dataEncrypted: serializer.fromJson<String>(json['data_encrypted']),
      isFavorite: serializer.fromJson<bool>(json['is_favorite']),
      deletedAt: serializer.fromJson<int?>(json['deleted_at']),
      createdAt: serializer.fromJson<int>(json['created_at']),
      updatedAt: serializer.fromJson<int>(json['updated_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'folder_id': serializer.toJson<String?>(folderId),
      'type': serializer.toJson<String>(type),
      'name': serializer.toJson<String>(name),
      'url': serializer.toJson<String>(url),
      'username': serializer.toJson<String>(username),
      'password_encrypted': serializer.toJson<String>(passwordEncrypted),
      'notes_encrypted': serializer.toJson<String?>(notesEncrypted),
      'totp_secret_encrypted': serializer.toJson<String?>(totpSecretEncrypted),
      'data_encrypted': serializer.toJson<String>(dataEncrypted),
      'is_favorite': serializer.toJson<bool>(isFavorite),
      'deleted_at': serializer.toJson<int?>(deletedAt),
      'created_at': serializer.toJson<int>(createdAt),
      'updated_at': serializer.toJson<int>(updatedAt),
    };
  }

  PasswordEntry copyWith({
    String? id,
    Value<String?> folderId = const Value.absent(),
    String? type,
    String? name,
    String? url,
    String? username,
    String? passwordEncrypted,
    Value<String?> notesEncrypted = const Value.absent(),
    Value<String?> totpSecretEncrypted = const Value.absent(),
    String? dataEncrypted,
    bool? isFavorite,
    Value<int?> deletedAt = const Value.absent(),
    int? createdAt,
    int? updatedAt,
  }) => PasswordEntry(
    id: id ?? this.id,
    folderId: folderId.present ? folderId.value : this.folderId,
    type: type ?? this.type,
    name: name ?? this.name,
    url: url ?? this.url,
    username: username ?? this.username,
    passwordEncrypted: passwordEncrypted ?? this.passwordEncrypted,
    notesEncrypted: notesEncrypted.present
        ? notesEncrypted.value
        : this.notesEncrypted,
    totpSecretEncrypted: totpSecretEncrypted.present
        ? totpSecretEncrypted.value
        : this.totpSecretEncrypted,
    dataEncrypted: dataEncrypted ?? this.dataEncrypted,
    isFavorite: isFavorite ?? this.isFavorite,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  PasswordEntry copyWithCompanion(PasswordEntriesCompanion data) {
    return PasswordEntry(
      id: data.id.present ? data.id.value : this.id,
      folderId: data.folderId.present ? data.folderId.value : this.folderId,
      type: data.type.present ? data.type.value : this.type,
      name: data.name.present ? data.name.value : this.name,
      url: data.url.present ? data.url.value : this.url,
      username: data.username.present ? data.username.value : this.username,
      passwordEncrypted: data.passwordEncrypted.present
          ? data.passwordEncrypted.value
          : this.passwordEncrypted,
      notesEncrypted: data.notesEncrypted.present
          ? data.notesEncrypted.value
          : this.notesEncrypted,
      totpSecretEncrypted: data.totpSecretEncrypted.present
          ? data.totpSecretEncrypted.value
          : this.totpSecretEncrypted,
      dataEncrypted: data.dataEncrypted.present
          ? data.dataEncrypted.value
          : this.dataEncrypted,
      isFavorite: data.isFavorite.present
          ? data.isFavorite.value
          : this.isFavorite,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PasswordEntry(')
          ..write('id: $id, ')
          ..write('folderId: $folderId, ')
          ..write('type: $type, ')
          ..write('name: $name, ')
          ..write('url: $url, ')
          ..write('username: $username, ')
          ..write('passwordEncrypted: $passwordEncrypted, ')
          ..write('notesEncrypted: $notesEncrypted, ')
          ..write('totpSecretEncrypted: $totpSecretEncrypted, ')
          ..write('dataEncrypted: $dataEncrypted, ')
          ..write('isFavorite: $isFavorite, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    folderId,
    type,
    name,
    url,
    username,
    passwordEncrypted,
    notesEncrypted,
    totpSecretEncrypted,
    dataEncrypted,
    isFavorite,
    deletedAt,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PasswordEntry &&
          other.id == this.id &&
          other.folderId == this.folderId &&
          other.type == this.type &&
          other.name == this.name &&
          other.url == this.url &&
          other.username == this.username &&
          other.passwordEncrypted == this.passwordEncrypted &&
          other.notesEncrypted == this.notesEncrypted &&
          other.totpSecretEncrypted == this.totpSecretEncrypted &&
          other.dataEncrypted == this.dataEncrypted &&
          other.isFavorite == this.isFavorite &&
          other.deletedAt == this.deletedAt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class PasswordEntriesCompanion extends UpdateCompanion<PasswordEntry> {
  final Value<String> id;
  final Value<String?> folderId;
  final Value<String> type;
  final Value<String> name;
  final Value<String> url;
  final Value<String> username;
  final Value<String> passwordEncrypted;
  final Value<String?> notesEncrypted;
  final Value<String?> totpSecretEncrypted;
  final Value<String> dataEncrypted;
  final Value<bool> isFavorite;
  final Value<int?> deletedAt;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const PasswordEntriesCompanion({
    this.id = const Value.absent(),
    this.folderId = const Value.absent(),
    this.type = const Value.absent(),
    this.name = const Value.absent(),
    this.url = const Value.absent(),
    this.username = const Value.absent(),
    this.passwordEncrypted = const Value.absent(),
    this.notesEncrypted = const Value.absent(),
    this.totpSecretEncrypted = const Value.absent(),
    this.dataEncrypted = const Value.absent(),
    this.isFavorite = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PasswordEntriesCompanion.insert({
    required String id,
    this.folderId = const Value.absent(),
    this.type = const Value.absent(),
    required String name,
    this.url = const Value.absent(),
    this.username = const Value.absent(),
    required String passwordEncrypted,
    this.notesEncrypted = const Value.absent(),
    this.totpSecretEncrypted = const Value.absent(),
    this.dataEncrypted = const Value.absent(),
    this.isFavorite = const Value.absent(),
    this.deletedAt = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       passwordEncrypted = Value(passwordEncrypted),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<PasswordEntry> custom({
    Expression<String>? id,
    Expression<String>? folderId,
    Expression<String>? type,
    Expression<String>? name,
    Expression<String>? url,
    Expression<String>? username,
    Expression<String>? passwordEncrypted,
    Expression<String>? notesEncrypted,
    Expression<String>? totpSecretEncrypted,
    Expression<String>? dataEncrypted,
    Expression<bool>? isFavorite,
    Expression<int>? deletedAt,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (folderId != null) 'folder_id': folderId,
      if (type != null) 'type': type,
      if (name != null) 'name': name,
      if (url != null) 'url': url,
      if (username != null) 'username': username,
      if (passwordEncrypted != null) 'password_encrypted': passwordEncrypted,
      if (notesEncrypted != null) 'notes_encrypted': notesEncrypted,
      if (totpSecretEncrypted != null)
        'totp_secret_encrypted': totpSecretEncrypted,
      if (dataEncrypted != null) 'data_encrypted': dataEncrypted,
      if (isFavorite != null) 'is_favorite': isFavorite,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PasswordEntriesCompanion copyWith({
    Value<String>? id,
    Value<String?>? folderId,
    Value<String>? type,
    Value<String>? name,
    Value<String>? url,
    Value<String>? username,
    Value<String>? passwordEncrypted,
    Value<String?>? notesEncrypted,
    Value<String?>? totpSecretEncrypted,
    Value<String>? dataEncrypted,
    Value<bool>? isFavorite,
    Value<int?>? deletedAt,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return PasswordEntriesCompanion(
      id: id ?? this.id,
      folderId: folderId ?? this.folderId,
      type: type ?? this.type,
      name: name ?? this.name,
      url: url ?? this.url,
      username: username ?? this.username,
      passwordEncrypted: passwordEncrypted ?? this.passwordEncrypted,
      notesEncrypted: notesEncrypted ?? this.notesEncrypted,
      totpSecretEncrypted: totpSecretEncrypted ?? this.totpSecretEncrypted,
      dataEncrypted: dataEncrypted ?? this.dataEncrypted,
      isFavorite: isFavorite ?? this.isFavorite,
      deletedAt: deletedAt ?? this.deletedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (folderId.present) {
      map['folder_id'] = Variable<String>(folderId.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (url.present) {
      map['url'] = Variable<String>(url.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (passwordEncrypted.present) {
      map['password_encrypted'] = Variable<String>(passwordEncrypted.value);
    }
    if (notesEncrypted.present) {
      map['notes_encrypted'] = Variable<String>(notesEncrypted.value);
    }
    if (totpSecretEncrypted.present) {
      map['totp_secret_encrypted'] = Variable<String>(
        totpSecretEncrypted.value,
      );
    }
    if (dataEncrypted.present) {
      map['data_encrypted'] = Variable<String>(dataEncrypted.value);
    }
    if (isFavorite.present) {
      map['is_favorite'] = Variable<bool>(isFavorite.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PasswordEntriesCompanion(')
          ..write('id: $id, ')
          ..write('folderId: $folderId, ')
          ..write('type: $type, ')
          ..write('name: $name, ')
          ..write('url: $url, ')
          ..write('username: $username, ')
          ..write('passwordEncrypted: $passwordEncrypted, ')
          ..write('notesEncrypted: $notesEncrypted, ')
          ..write('totpSecretEncrypted: $totpSecretEncrypted, ')
          ..write('dataEncrypted: $dataEncrypted, ')
          ..write('isFavorite: $isFavorite, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class VaultMeta extends Table with TableInfo<VaultMeta, VaultMetaData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  VaultMeta(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _metaKeyMeta = const VerificationMeta(
    'metaKey',
  );
  late final GeneratedColumn<String> metaKey = GeneratedColumn<String>(
    'meta_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'PRIMARY KEY NOT NULL',
  );
  static const VerificationMeta _metaValueMeta = const VerificationMeta(
    'metaValue',
  );
  late final GeneratedColumn<String> metaValue = GeneratedColumn<String>(
    'meta_value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [metaKey, metaValue];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'vault_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<VaultMetaData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('meta_key')) {
      context.handle(
        _metaKeyMeta,
        metaKey.isAcceptableOrUnknown(data['meta_key']!, _metaKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_metaKeyMeta);
    }
    if (data.containsKey('meta_value')) {
      context.handle(
        _metaValueMeta,
        metaValue.isAcceptableOrUnknown(data['meta_value']!, _metaValueMeta),
      );
    } else if (isInserting) {
      context.missing(_metaValueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {metaKey};
  @override
  VaultMetaData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VaultMetaData(
      metaKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}meta_key'],
      )!,
      metaValue: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}meta_value'],
      )!,
    );
  }

  @override
  VaultMeta createAlias(String alias) {
    return VaultMeta(attachedDatabase, alias);
  }

  @override
  bool get dontWriteConstraints => true;
}

class VaultMetaData extends DataClass implements Insertable<VaultMetaData> {
  final String metaKey;
  final String metaValue;
  const VaultMetaData({required this.metaKey, required this.metaValue});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['meta_key'] = Variable<String>(metaKey);
    map['meta_value'] = Variable<String>(metaValue);
    return map;
  }

  VaultMetaCompanion toCompanion(bool nullToAbsent) {
    return VaultMetaCompanion(
      metaKey: Value(metaKey),
      metaValue: Value(metaValue),
    );
  }

  factory VaultMetaData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VaultMetaData(
      metaKey: serializer.fromJson<String>(json['meta_key']),
      metaValue: serializer.fromJson<String>(json['meta_value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'meta_key': serializer.toJson<String>(metaKey),
      'meta_value': serializer.toJson<String>(metaValue),
    };
  }

  VaultMetaData copyWith({String? metaKey, String? metaValue}) => VaultMetaData(
    metaKey: metaKey ?? this.metaKey,
    metaValue: metaValue ?? this.metaValue,
  );
  VaultMetaData copyWithCompanion(VaultMetaCompanion data) {
    return VaultMetaData(
      metaKey: data.metaKey.present ? data.metaKey.value : this.metaKey,
      metaValue: data.metaValue.present ? data.metaValue.value : this.metaValue,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VaultMetaData(')
          ..write('metaKey: $metaKey, ')
          ..write('metaValue: $metaValue')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(metaKey, metaValue);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VaultMetaData &&
          other.metaKey == this.metaKey &&
          other.metaValue == this.metaValue);
}

class VaultMetaCompanion extends UpdateCompanion<VaultMetaData> {
  final Value<String> metaKey;
  final Value<String> metaValue;
  final Value<int> rowid;
  const VaultMetaCompanion({
    this.metaKey = const Value.absent(),
    this.metaValue = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VaultMetaCompanion.insert({
    required String metaKey,
    required String metaValue,
    this.rowid = const Value.absent(),
  }) : metaKey = Value(metaKey),
       metaValue = Value(metaValue);
  static Insertable<VaultMetaData> custom({
    Expression<String>? metaKey,
    Expression<String>? metaValue,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (metaKey != null) 'meta_key': metaKey,
      if (metaValue != null) 'meta_value': metaValue,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VaultMetaCompanion copyWith({
    Value<String>? metaKey,
    Value<String>? metaValue,
    Value<int>? rowid,
  }) {
    return VaultMetaCompanion(
      metaKey: metaKey ?? this.metaKey,
      metaValue: metaValue ?? this.metaValue,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (metaKey.present) {
      map['meta_key'] = Variable<String>(metaKey.value);
    }
    if (metaValue.present) {
      map['meta_value'] = Variable<String>(metaValue.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VaultMetaCompanion(')
          ..write('metaKey: $metaKey, ')
          ..write('metaValue: $metaValue, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class AgentAudit extends Table with TableInfo<AgentAudit, AgentAuditData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  AgentAudit(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    $customConstraints: 'NOT NULL PRIMARY KEY AUTOINCREMENT',
  );
  static const VerificationMeta _atMeta = const VerificationMeta('at');
  late final GeneratedColumn<int> at = GeneratedColumn<int>(
    'at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _pairingIdMeta = const VerificationMeta(
    'pairingId',
  );
  late final GeneratedColumn<String> pairingId = GeneratedColumn<String>(
    'pairing_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _nicknameMeta = const VerificationMeta(
    'nickname',
  );
  late final GeneratedColumn<String> nickname = GeneratedColumn<String>(
    'nickname',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _modeMeta = const VerificationMeta('mode');
  late final GeneratedColumn<String> mode = GeneratedColumn<String>(
    'mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _toolMeta = const VerificationMeta('tool');
  late final GeneratedColumn<String> tool = GeneratedColumn<String>(
    'tool',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _opMeta = const VerificationMeta('op');
  late final GeneratedColumn<String> op = GeneratedColumn<String>(
    'op',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  static const VerificationMeta _entryIdMeta = const VerificationMeta(
    'entryId',
  );
  late final GeneratedColumn<String> entryId = GeneratedColumn<String>(
    'entry_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _entryNameMeta = const VerificationMeta(
    'entryName',
  );
  late final GeneratedColumn<String> entryName = GeneratedColumn<String>(
    'entry_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    $customConstraints: '',
  );
  static const VerificationMeta _decisionMeta = const VerificationMeta(
    'decision',
  );
  late final GeneratedColumn<String> decision = GeneratedColumn<String>(
    'decision',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL',
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    at,
    pairingId,
    nickname,
    mode,
    tool,
    op,
    entryId,
    entryName,
    decision,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'agent_audit';
  @override
  VerificationContext validateIntegrity(
    Insertable<AgentAuditData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('at')) {
      context.handle(_atMeta, at.isAcceptableOrUnknown(data['at']!, _atMeta));
    } else if (isInserting) {
      context.missing(_atMeta);
    }
    if (data.containsKey('pairing_id')) {
      context.handle(
        _pairingIdMeta,
        pairingId.isAcceptableOrUnknown(data['pairing_id']!, _pairingIdMeta),
      );
    } else if (isInserting) {
      context.missing(_pairingIdMeta);
    }
    if (data.containsKey('nickname')) {
      context.handle(
        _nicknameMeta,
        nickname.isAcceptableOrUnknown(data['nickname']!, _nicknameMeta),
      );
    } else if (isInserting) {
      context.missing(_nicknameMeta);
    }
    if (data.containsKey('mode')) {
      context.handle(
        _modeMeta,
        mode.isAcceptableOrUnknown(data['mode']!, _modeMeta),
      );
    } else if (isInserting) {
      context.missing(_modeMeta);
    }
    if (data.containsKey('tool')) {
      context.handle(
        _toolMeta,
        tool.isAcceptableOrUnknown(data['tool']!, _toolMeta),
      );
    } else if (isInserting) {
      context.missing(_toolMeta);
    }
    if (data.containsKey('op')) {
      context.handle(_opMeta, op.isAcceptableOrUnknown(data['op']!, _opMeta));
    } else if (isInserting) {
      context.missing(_opMeta);
    }
    if (data.containsKey('entry_id')) {
      context.handle(
        _entryIdMeta,
        entryId.isAcceptableOrUnknown(data['entry_id']!, _entryIdMeta),
      );
    }
    if (data.containsKey('entry_name')) {
      context.handle(
        _entryNameMeta,
        entryName.isAcceptableOrUnknown(data['entry_name']!, _entryNameMeta),
      );
    }
    if (data.containsKey('decision')) {
      context.handle(
        _decisionMeta,
        decision.isAcceptableOrUnknown(data['decision']!, _decisionMeta),
      );
    } else if (isInserting) {
      context.missing(_decisionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AgentAuditData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AgentAuditData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      at: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}at'],
      )!,
      pairingId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pairing_id'],
      )!,
      nickname: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}nickname'],
      )!,
      mode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mode'],
      )!,
      tool: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tool'],
      )!,
      op: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}op'],
      )!,
      entryId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entry_id'],
      ),
      entryName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entry_name'],
      ),
      decision: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}decision'],
      )!,
    );
  }

  @override
  AgentAudit createAlias(String alias) {
    return AgentAudit(attachedDatabase, alias);
  }

  @override
  bool get dontWriteConstraints => true;
}

class AgentAuditData extends DataClass implements Insertable<AgentAuditData> {
  final int id;
  final int at;
  final String pairingId;
  final String nickname;
  final String mode;
  final String tool;
  final String op;
  final String? entryId;
  final String? entryName;
  final String decision;
  const AgentAuditData({
    required this.id,
    required this.at,
    required this.pairingId,
    required this.nickname,
    required this.mode,
    required this.tool,
    required this.op,
    this.entryId,
    this.entryName,
    required this.decision,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['at'] = Variable<int>(at);
    map['pairing_id'] = Variable<String>(pairingId);
    map['nickname'] = Variable<String>(nickname);
    map['mode'] = Variable<String>(mode);
    map['tool'] = Variable<String>(tool);
    map['op'] = Variable<String>(op);
    if (!nullToAbsent || entryId != null) {
      map['entry_id'] = Variable<String>(entryId);
    }
    if (!nullToAbsent || entryName != null) {
      map['entry_name'] = Variable<String>(entryName);
    }
    map['decision'] = Variable<String>(decision);
    return map;
  }

  AgentAuditCompanion toCompanion(bool nullToAbsent) {
    return AgentAuditCompanion(
      id: Value(id),
      at: Value(at),
      pairingId: Value(pairingId),
      nickname: Value(nickname),
      mode: Value(mode),
      tool: Value(tool),
      op: Value(op),
      entryId: entryId == null && nullToAbsent
          ? const Value.absent()
          : Value(entryId),
      entryName: entryName == null && nullToAbsent
          ? const Value.absent()
          : Value(entryName),
      decision: Value(decision),
    );
  }

  factory AgentAuditData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AgentAuditData(
      id: serializer.fromJson<int>(json['id']),
      at: serializer.fromJson<int>(json['at']),
      pairingId: serializer.fromJson<String>(json['pairing_id']),
      nickname: serializer.fromJson<String>(json['nickname']),
      mode: serializer.fromJson<String>(json['mode']),
      tool: serializer.fromJson<String>(json['tool']),
      op: serializer.fromJson<String>(json['op']),
      entryId: serializer.fromJson<String?>(json['entry_id']),
      entryName: serializer.fromJson<String?>(json['entry_name']),
      decision: serializer.fromJson<String>(json['decision']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'at': serializer.toJson<int>(at),
      'pairing_id': serializer.toJson<String>(pairingId),
      'nickname': serializer.toJson<String>(nickname),
      'mode': serializer.toJson<String>(mode),
      'tool': serializer.toJson<String>(tool),
      'op': serializer.toJson<String>(op),
      'entry_id': serializer.toJson<String?>(entryId),
      'entry_name': serializer.toJson<String?>(entryName),
      'decision': serializer.toJson<String>(decision),
    };
  }

  AgentAuditData copyWith({
    int? id,
    int? at,
    String? pairingId,
    String? nickname,
    String? mode,
    String? tool,
    String? op,
    Value<String?> entryId = const Value.absent(),
    Value<String?> entryName = const Value.absent(),
    String? decision,
  }) => AgentAuditData(
    id: id ?? this.id,
    at: at ?? this.at,
    pairingId: pairingId ?? this.pairingId,
    nickname: nickname ?? this.nickname,
    mode: mode ?? this.mode,
    tool: tool ?? this.tool,
    op: op ?? this.op,
    entryId: entryId.present ? entryId.value : this.entryId,
    entryName: entryName.present ? entryName.value : this.entryName,
    decision: decision ?? this.decision,
  );
  AgentAuditData copyWithCompanion(AgentAuditCompanion data) {
    return AgentAuditData(
      id: data.id.present ? data.id.value : this.id,
      at: data.at.present ? data.at.value : this.at,
      pairingId: data.pairingId.present ? data.pairingId.value : this.pairingId,
      nickname: data.nickname.present ? data.nickname.value : this.nickname,
      mode: data.mode.present ? data.mode.value : this.mode,
      tool: data.tool.present ? data.tool.value : this.tool,
      op: data.op.present ? data.op.value : this.op,
      entryId: data.entryId.present ? data.entryId.value : this.entryId,
      entryName: data.entryName.present ? data.entryName.value : this.entryName,
      decision: data.decision.present ? data.decision.value : this.decision,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AgentAuditData(')
          ..write('id: $id, ')
          ..write('at: $at, ')
          ..write('pairingId: $pairingId, ')
          ..write('nickname: $nickname, ')
          ..write('mode: $mode, ')
          ..write('tool: $tool, ')
          ..write('op: $op, ')
          ..write('entryId: $entryId, ')
          ..write('entryName: $entryName, ')
          ..write('decision: $decision')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    at,
    pairingId,
    nickname,
    mode,
    tool,
    op,
    entryId,
    entryName,
    decision,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AgentAuditData &&
          other.id == this.id &&
          other.at == this.at &&
          other.pairingId == this.pairingId &&
          other.nickname == this.nickname &&
          other.mode == this.mode &&
          other.tool == this.tool &&
          other.op == this.op &&
          other.entryId == this.entryId &&
          other.entryName == this.entryName &&
          other.decision == this.decision);
}

class AgentAuditCompanion extends UpdateCompanion<AgentAuditData> {
  final Value<int> id;
  final Value<int> at;
  final Value<String> pairingId;
  final Value<String> nickname;
  final Value<String> mode;
  final Value<String> tool;
  final Value<String> op;
  final Value<String?> entryId;
  final Value<String?> entryName;
  final Value<String> decision;
  const AgentAuditCompanion({
    this.id = const Value.absent(),
    this.at = const Value.absent(),
    this.pairingId = const Value.absent(),
    this.nickname = const Value.absent(),
    this.mode = const Value.absent(),
    this.tool = const Value.absent(),
    this.op = const Value.absent(),
    this.entryId = const Value.absent(),
    this.entryName = const Value.absent(),
    this.decision = const Value.absent(),
  });
  AgentAuditCompanion.insert({
    this.id = const Value.absent(),
    required int at,
    required String pairingId,
    required String nickname,
    required String mode,
    required String tool,
    required String op,
    this.entryId = const Value.absent(),
    this.entryName = const Value.absent(),
    required String decision,
  }) : at = Value(at),
       pairingId = Value(pairingId),
       nickname = Value(nickname),
       mode = Value(mode),
       tool = Value(tool),
       op = Value(op),
       decision = Value(decision);
  static Insertable<AgentAuditData> custom({
    Expression<int>? id,
    Expression<int>? at,
    Expression<String>? pairingId,
    Expression<String>? nickname,
    Expression<String>? mode,
    Expression<String>? tool,
    Expression<String>? op,
    Expression<String>? entryId,
    Expression<String>? entryName,
    Expression<String>? decision,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (at != null) 'at': at,
      if (pairingId != null) 'pairing_id': pairingId,
      if (nickname != null) 'nickname': nickname,
      if (mode != null) 'mode': mode,
      if (tool != null) 'tool': tool,
      if (op != null) 'op': op,
      if (entryId != null) 'entry_id': entryId,
      if (entryName != null) 'entry_name': entryName,
      if (decision != null) 'decision': decision,
    });
  }

  AgentAuditCompanion copyWith({
    Value<int>? id,
    Value<int>? at,
    Value<String>? pairingId,
    Value<String>? nickname,
    Value<String>? mode,
    Value<String>? tool,
    Value<String>? op,
    Value<String?>? entryId,
    Value<String?>? entryName,
    Value<String>? decision,
  }) {
    return AgentAuditCompanion(
      id: id ?? this.id,
      at: at ?? this.at,
      pairingId: pairingId ?? this.pairingId,
      nickname: nickname ?? this.nickname,
      mode: mode ?? this.mode,
      tool: tool ?? this.tool,
      op: op ?? this.op,
      entryId: entryId ?? this.entryId,
      entryName: entryName ?? this.entryName,
      decision: decision ?? this.decision,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (at.present) {
      map['at'] = Variable<int>(at.value);
    }
    if (pairingId.present) {
      map['pairing_id'] = Variable<String>(pairingId.value);
    }
    if (nickname.present) {
      map['nickname'] = Variable<String>(nickname.value);
    }
    if (mode.present) {
      map['mode'] = Variable<String>(mode.value);
    }
    if (tool.present) {
      map['tool'] = Variable<String>(tool.value);
    }
    if (op.present) {
      map['op'] = Variable<String>(op.value);
    }
    if (entryId.present) {
      map['entry_id'] = Variable<String>(entryId.value);
    }
    if (entryName.present) {
      map['entry_name'] = Variable<String>(entryName.value);
    }
    if (decision.present) {
      map['decision'] = Variable<String>(decision.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AgentAuditCompanion(')
          ..write('id: $id, ')
          ..write('at: $at, ')
          ..write('pairingId: $pairingId, ')
          ..write('nickname: $nickname, ')
          ..write('mode: $mode, ')
          ..write('tool: $tool, ')
          ..write('op: $op, ')
          ..write('entryId: $entryId, ')
          ..write('entryName: $entryName, ')
          ..write('decision: $decision')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final Folders folders = Folders(this);
  late final PasswordEntries passwordEntries = PasswordEntries(this);
  late final Index idxPasswordEntriesFolder = Index(
    'idx_password_entries_folder',
    'CREATE INDEX idx_password_entries_folder ON password_entries (folder_id)',
  );
  late final Index idxPasswordEntriesName = Index(
    'idx_password_entries_name',
    'CREATE INDEX idx_password_entries_name ON password_entries (name)',
  );
  late final Index idxPasswordEntriesFavorite = Index(
    'idx_password_entries_favorite',
    'CREATE INDEX idx_password_entries_favorite ON password_entries (is_favorite)',
  );
  late final Index idxPasswordEntriesType = Index(
    'idx_password_entries_type',
    'CREATE INDEX idx_password_entries_type ON password_entries (type)',
  );
  late final Index idxPasswordEntriesDeleted = Index(
    'idx_password_entries_deleted',
    'CREATE INDEX idx_password_entries_deleted ON password_entries (deleted_at)',
  );
  late final VaultMeta vaultMeta = VaultMeta(this);
  late final AgentAudit agentAudit = AgentAudit(this);
  late final Index idxAgentAuditAt = Index(
    'idx_agent_audit_at',
    'CREATE INDEX idx_agent_audit_at ON agent_audit (at)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    folders,
    passwordEntries,
    idxPasswordEntriesFolder,
    idxPasswordEntriesName,
    idxPasswordEntriesFavorite,
    idxPasswordEntriesType,
    idxPasswordEntriesDeleted,
    vaultMeta,
    agentAudit,
    idxAgentAuditAt,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'folders',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('password_entries', kind: UpdateKind.update)],
    ),
  ]);
}

typedef $FoldersCreateCompanionBuilder =
    FoldersCompanion Function({
      required String id,
      required String name,
      Value<String?> icon,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $FoldersUpdateCompanionBuilder =
    FoldersCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String?> icon,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $FoldersFilterComposer extends Composer<_$AppDatabase, Folders> {
  $FoldersFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $FoldersOrderingComposer extends Composer<_$AppDatabase, Folders> {
  $FoldersOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get icon => $composableBuilder(
    column: $table.icon,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $FoldersAnnotationComposer extends Composer<_$AppDatabase, Folders> {
  $FoldersAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get icon =>
      $composableBuilder(column: $table.icon, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $FoldersTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          Folders,
          Folder,
          $FoldersFilterComposer,
          $FoldersOrderingComposer,
          $FoldersAnnotationComposer,
          $FoldersCreateCompanionBuilder,
          $FoldersUpdateCompanionBuilder,
          (Folder, BaseReferences<_$AppDatabase, Folders, Folder>),
          Folder,
          PrefetchHooks Function()
        > {
  $FoldersTableManager(_$AppDatabase db, Folders table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $FoldersFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $FoldersOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $FoldersAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> icon = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FoldersCompanion(
                id: id,
                name: name,
                icon: icon,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<String?> icon = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => FoldersCompanion.insert(
                id: id,
                name: name,
                icon: icon,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<Folders, Folder>(table),
                  BaseReferences<_$AppDatabase, Folders, Folder>(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $FoldersProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      Folders,
      Folder,
      $FoldersFilterComposer,
      $FoldersOrderingComposer,
      $FoldersAnnotationComposer,
      $FoldersCreateCompanionBuilder,
      $FoldersUpdateCompanionBuilder,
      (Folder, BaseReferences<_$AppDatabase, Folders, Folder>),
      Folder,
      PrefetchHooks Function()
    >;
typedef $PasswordEntriesCreateCompanionBuilder =
    PasswordEntriesCompanion Function({
      required String id,
      Value<String?> folderId,
      Value<String> type,
      required String name,
      Value<String> url,
      Value<String> username,
      required String passwordEncrypted,
      Value<String?> notesEncrypted,
      Value<String?> totpSecretEncrypted,
      Value<String> dataEncrypted,
      Value<bool> isFavorite,
      Value<int?> deletedAt,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $PasswordEntriesUpdateCompanionBuilder =
    PasswordEntriesCompanion Function({
      Value<String> id,
      Value<String?> folderId,
      Value<String> type,
      Value<String> name,
      Value<String> url,
      Value<String> username,
      Value<String> passwordEncrypted,
      Value<String?> notesEncrypted,
      Value<String?> totpSecretEncrypted,
      Value<String> dataEncrypted,
      Value<bool> isFavorite,
      Value<int?> deletedAt,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $PasswordEntriesFilterComposer
    extends Composer<_$AppDatabase, PasswordEntries> {
  $PasswordEntriesFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get passwordEncrypted => $composableBuilder(
    column: $table.passwordEncrypted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notesEncrypted => $composableBuilder(
    column: $table.notesEncrypted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get totpSecretEncrypted => $composableBuilder(
    column: $table.totpSecretEncrypted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dataEncrypted => $composableBuilder(
    column: $table.dataEncrypted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isFavorite => $composableBuilder(
    column: $table.isFavorite,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $PasswordEntriesOrderingComposer
    extends Composer<_$AppDatabase, PasswordEntries> {
  $PasswordEntriesOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get passwordEncrypted => $composableBuilder(
    column: $table.passwordEncrypted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notesEncrypted => $composableBuilder(
    column: $table.notesEncrypted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get totpSecretEncrypted => $composableBuilder(
    column: $table.totpSecretEncrypted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dataEncrypted => $composableBuilder(
    column: $table.dataEncrypted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isFavorite => $composableBuilder(
    column: $table.isFavorite,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $PasswordEntriesAnnotationComposer
    extends Composer<_$AppDatabase, PasswordEntries> {
  $PasswordEntriesAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get folderId =>
      $composableBuilder(column: $table.folderId, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get url =>
      $composableBuilder(column: $table.url, builder: (column) => column);

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get passwordEncrypted => $composableBuilder(
    column: $table.passwordEncrypted,
    builder: (column) => column,
  );

  GeneratedColumn<String> get notesEncrypted => $composableBuilder(
    column: $table.notesEncrypted,
    builder: (column) => column,
  );

  GeneratedColumn<String> get totpSecretEncrypted => $composableBuilder(
    column: $table.totpSecretEncrypted,
    builder: (column) => column,
  );

  GeneratedColumn<String> get dataEncrypted => $composableBuilder(
    column: $table.dataEncrypted,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isFavorite => $composableBuilder(
    column: $table.isFavorite,
    builder: (column) => column,
  );

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $PasswordEntriesTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          PasswordEntries,
          PasswordEntry,
          $PasswordEntriesFilterComposer,
          $PasswordEntriesOrderingComposer,
          $PasswordEntriesAnnotationComposer,
          $PasswordEntriesCreateCompanionBuilder,
          $PasswordEntriesUpdateCompanionBuilder,
          (
            PasswordEntry,
            BaseReferences<_$AppDatabase, PasswordEntries, PasswordEntry>,
          ),
          PasswordEntry,
          PrefetchHooks Function()
        > {
  $PasswordEntriesTableManager(_$AppDatabase db, PasswordEntries table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $PasswordEntriesFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $PasswordEntriesOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $PasswordEntriesAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String?> folderId = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> url = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String> passwordEncrypted = const Value.absent(),
                Value<String?> notesEncrypted = const Value.absent(),
                Value<String?> totpSecretEncrypted = const Value.absent(),
                Value<String> dataEncrypted = const Value.absent(),
                Value<bool> isFavorite = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PasswordEntriesCompanion(
                id: id,
                folderId: folderId,
                type: type,
                name: name,
                url: url,
                username: username,
                passwordEncrypted: passwordEncrypted,
                notesEncrypted: notesEncrypted,
                totpSecretEncrypted: totpSecretEncrypted,
                dataEncrypted: dataEncrypted,
                isFavorite: isFavorite,
                deletedAt: deletedAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String?> folderId = const Value.absent(),
                Value<String> type = const Value.absent(),
                required String name,
                Value<String> url = const Value.absent(),
                Value<String> username = const Value.absent(),
                required String passwordEncrypted,
                Value<String?> notesEncrypted = const Value.absent(),
                Value<String?> totpSecretEncrypted = const Value.absent(),
                Value<String> dataEncrypted = const Value.absent(),
                Value<bool> isFavorite = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => PasswordEntriesCompanion.insert(
                id: id,
                folderId: folderId,
                type: type,
                name: name,
                url: url,
                username: username,
                passwordEncrypted: passwordEncrypted,
                notesEncrypted: notesEncrypted,
                totpSecretEncrypted: totpSecretEncrypted,
                dataEncrypted: dataEncrypted,
                isFavorite: isFavorite,
                deletedAt: deletedAt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<PasswordEntries, PasswordEntry>(table),
                  BaseReferences<_$AppDatabase, PasswordEntries, PasswordEntry>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $PasswordEntriesProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      PasswordEntries,
      PasswordEntry,
      $PasswordEntriesFilterComposer,
      $PasswordEntriesOrderingComposer,
      $PasswordEntriesAnnotationComposer,
      $PasswordEntriesCreateCompanionBuilder,
      $PasswordEntriesUpdateCompanionBuilder,
      (
        PasswordEntry,
        BaseReferences<_$AppDatabase, PasswordEntries, PasswordEntry>,
      ),
      PasswordEntry,
      PrefetchHooks Function()
    >;
typedef $VaultMetaCreateCompanionBuilder =
    VaultMetaCompanion Function({
      required String metaKey,
      required String metaValue,
      Value<int> rowid,
    });
typedef $VaultMetaUpdateCompanionBuilder =
    VaultMetaCompanion Function({
      Value<String> metaKey,
      Value<String> metaValue,
      Value<int> rowid,
    });

class $VaultMetaFilterComposer extends Composer<_$AppDatabase, VaultMeta> {
  $VaultMetaFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get metaKey => $composableBuilder(
    column: $table.metaKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get metaValue => $composableBuilder(
    column: $table.metaValue,
    builder: (column) => ColumnFilters(column),
  );
}

class $VaultMetaOrderingComposer extends Composer<_$AppDatabase, VaultMeta> {
  $VaultMetaOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get metaKey => $composableBuilder(
    column: $table.metaKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metaValue => $composableBuilder(
    column: $table.metaValue,
    builder: (column) => ColumnOrderings(column),
  );
}

class $VaultMetaAnnotationComposer extends Composer<_$AppDatabase, VaultMeta> {
  $VaultMetaAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get metaKey =>
      $composableBuilder(column: $table.metaKey, builder: (column) => column);

  GeneratedColumn<String> get metaValue =>
      $composableBuilder(column: $table.metaValue, builder: (column) => column);
}

class $VaultMetaTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          VaultMeta,
          VaultMetaData,
          $VaultMetaFilterComposer,
          $VaultMetaOrderingComposer,
          $VaultMetaAnnotationComposer,
          $VaultMetaCreateCompanionBuilder,
          $VaultMetaUpdateCompanionBuilder,
          (
            VaultMetaData,
            BaseReferences<_$AppDatabase, VaultMeta, VaultMetaData>,
          ),
          VaultMetaData,
          PrefetchHooks Function()
        > {
  $VaultMetaTableManager(_$AppDatabase db, VaultMeta table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $VaultMetaFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $VaultMetaOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $VaultMetaAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> metaKey = const Value.absent(),
                Value<String> metaValue = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultMetaCompanion(
                metaKey: metaKey,
                metaValue: metaValue,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String metaKey,
                required String metaValue,
                Value<int> rowid = const Value.absent(),
              }) => VaultMetaCompanion.insert(
                metaKey: metaKey,
                metaValue: metaValue,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<VaultMeta, VaultMetaData>(table),
                  BaseReferences<_$AppDatabase, VaultMeta, VaultMetaData>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $VaultMetaProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      VaultMeta,
      VaultMetaData,
      $VaultMetaFilterComposer,
      $VaultMetaOrderingComposer,
      $VaultMetaAnnotationComposer,
      $VaultMetaCreateCompanionBuilder,
      $VaultMetaUpdateCompanionBuilder,
      (VaultMetaData, BaseReferences<_$AppDatabase, VaultMeta, VaultMetaData>),
      VaultMetaData,
      PrefetchHooks Function()
    >;
typedef $AgentAuditCreateCompanionBuilder =
    AgentAuditCompanion Function({
      Value<int> id,
      required int at,
      required String pairingId,
      required String nickname,
      required String mode,
      required String tool,
      required String op,
      Value<String?> entryId,
      Value<String?> entryName,
      required String decision,
    });
typedef $AgentAuditUpdateCompanionBuilder =
    AgentAuditCompanion Function({
      Value<int> id,
      Value<int> at,
      Value<String> pairingId,
      Value<String> nickname,
      Value<String> mode,
      Value<String> tool,
      Value<String> op,
      Value<String?> entryId,
      Value<String?> entryName,
      Value<String> decision,
    });

class $AgentAuditFilterComposer extends Composer<_$AppDatabase, AgentAudit> {
  $AgentAuditFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get at => $composableBuilder(
    column: $table.at,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pairingId => $composableBuilder(
    column: $table.pairingId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nickname => $composableBuilder(
    column: $table.nickname,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mode => $composableBuilder(
    column: $table.mode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tool => $composableBuilder(
    column: $table.tool,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get op => $composableBuilder(
    column: $table.op,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entryId => $composableBuilder(
    column: $table.entryId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entryName => $composableBuilder(
    column: $table.entryName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get decision => $composableBuilder(
    column: $table.decision,
    builder: (column) => ColumnFilters(column),
  );
}

class $AgentAuditOrderingComposer extends Composer<_$AppDatabase, AgentAudit> {
  $AgentAuditOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get at => $composableBuilder(
    column: $table.at,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pairingId => $composableBuilder(
    column: $table.pairingId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nickname => $composableBuilder(
    column: $table.nickname,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mode => $composableBuilder(
    column: $table.mode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tool => $composableBuilder(
    column: $table.tool,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get op => $composableBuilder(
    column: $table.op,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entryId => $composableBuilder(
    column: $table.entryId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entryName => $composableBuilder(
    column: $table.entryName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get decision => $composableBuilder(
    column: $table.decision,
    builder: (column) => ColumnOrderings(column),
  );
}

class $AgentAuditAnnotationComposer
    extends Composer<_$AppDatabase, AgentAudit> {
  $AgentAuditAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get at =>
      $composableBuilder(column: $table.at, builder: (column) => column);

  GeneratedColumn<String> get pairingId =>
      $composableBuilder(column: $table.pairingId, builder: (column) => column);

  GeneratedColumn<String> get nickname =>
      $composableBuilder(column: $table.nickname, builder: (column) => column);

  GeneratedColumn<String> get mode =>
      $composableBuilder(column: $table.mode, builder: (column) => column);

  GeneratedColumn<String> get tool =>
      $composableBuilder(column: $table.tool, builder: (column) => column);

  GeneratedColumn<String> get op =>
      $composableBuilder(column: $table.op, builder: (column) => column);

  GeneratedColumn<String> get entryId =>
      $composableBuilder(column: $table.entryId, builder: (column) => column);

  GeneratedColumn<String> get entryName =>
      $composableBuilder(column: $table.entryName, builder: (column) => column);

  GeneratedColumn<String> get decision =>
      $composableBuilder(column: $table.decision, builder: (column) => column);
}

class $AgentAuditTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          AgentAudit,
          AgentAuditData,
          $AgentAuditFilterComposer,
          $AgentAuditOrderingComposer,
          $AgentAuditAnnotationComposer,
          $AgentAuditCreateCompanionBuilder,
          $AgentAuditUpdateCompanionBuilder,
          (
            AgentAuditData,
            BaseReferences<_$AppDatabase, AgentAudit, AgentAuditData>,
          ),
          AgentAuditData,
          PrefetchHooks Function()
        > {
  $AgentAuditTableManager(_$AppDatabase db, AgentAudit table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $AgentAuditFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $AgentAuditOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $AgentAuditAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> at = const Value.absent(),
                Value<String> pairingId = const Value.absent(),
                Value<String> nickname = const Value.absent(),
                Value<String> mode = const Value.absent(),
                Value<String> tool = const Value.absent(),
                Value<String> op = const Value.absent(),
                Value<String?> entryId = const Value.absent(),
                Value<String?> entryName = const Value.absent(),
                Value<String> decision = const Value.absent(),
              }) => AgentAuditCompanion(
                id: id,
                at: at,
                pairingId: pairingId,
                nickname: nickname,
                mode: mode,
                tool: tool,
                op: op,
                entryId: entryId,
                entryName: entryName,
                decision: decision,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int at,
                required String pairingId,
                required String nickname,
                required String mode,
                required String tool,
                required String op,
                Value<String?> entryId = const Value.absent(),
                Value<String?> entryName = const Value.absent(),
                required String decision,
              }) => AgentAuditCompanion.insert(
                id: id,
                at: at,
                pairingId: pairingId,
                nickname: nickname,
                mode: mode,
                tool: tool,
                op: op,
                entryId: entryId,
                entryName: entryName,
                decision: decision,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<AgentAudit, AgentAuditData>(table),
                  BaseReferences<_$AppDatabase, AgentAudit, AgentAuditData>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $AgentAuditProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      AgentAudit,
      AgentAuditData,
      $AgentAuditFilterComposer,
      $AgentAuditOrderingComposer,
      $AgentAuditAnnotationComposer,
      $AgentAuditCreateCompanionBuilder,
      $AgentAuditUpdateCompanionBuilder,
      (
        AgentAuditData,
        BaseReferences<_$AppDatabase, AgentAudit, AgentAuditData>,
      ),
      AgentAuditData,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $FoldersTableManager get folders => $FoldersTableManager(_db, _db.folders);
  $PasswordEntriesTableManager get passwordEntries =>
      $PasswordEntriesTableManager(_db, _db.passwordEntries);
  $VaultMetaTableManager get vaultMeta =>
      $VaultMetaTableManager(_db, _db.vaultMeta);
  $AgentAuditTableManager get agentAudit =>
      $AgentAuditTableManager(_db, _db.agentAudit);
}
