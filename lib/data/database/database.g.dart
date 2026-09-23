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
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
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

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $FoldersTableManager get folders => $FoldersTableManager(_db, _db.folders);
  $PasswordEntriesTableManager get passwordEntries =>
      $PasswordEntriesTableManager(_db, _db.passwordEntries);
}
