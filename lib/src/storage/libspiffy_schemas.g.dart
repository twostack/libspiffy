// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'libspiffy_schemas.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetBlockHeaderEntityCollection on Isar {
  IsarCollection<BlockHeaderEntity> get blockHeaderEntitys => this.collection();
}

const BlockHeaderEntitySchema = CollectionSchema(
  name: r'BlockHeaderEntity',
  id: 6269092351188696736,
  properties: {
    r'bits': PropertySchema(
      id: 0,
      name: r'bits',
      type: IsarType.long,
    ),
    r'hash': PropertySchema(
      id: 1,
      name: r'hash',
      type: IsarType.string,
    ),
    r'height': PropertySchema(
      id: 2,
      name: r'height',
      type: IsarType.long,
    ),
    r'isOrphaned': PropertySchema(
      id: 3,
      name: r'isOrphaned',
      type: IsarType.bool,
    ),
    r'merkleRoot': PropertySchema(
      id: 4,
      name: r'merkleRoot',
      type: IsarType.string,
    ),
    r'nonce': PropertySchema(
      id: 5,
      name: r'nonce',
      type: IsarType.long,
    ),
    r'prevBlockHash': PropertySchema(
      id: 6,
      name: r'prevBlockHash',
      type: IsarType.string,
    ),
    r'storedAt': PropertySchema(
      id: 7,
      name: r'storedAt',
      type: IsarType.dateTime,
    ),
    r'timestamp': PropertySchema(
      id: 8,
      name: r'timestamp',
      type: IsarType.long,
    ),
    r'version': PropertySchema(
      id: 9,
      name: r'version',
      type: IsarType.long,
    )
  },
  estimateSize: _blockHeaderEntityEstimateSize,
  serialize: _blockHeaderEntitySerialize,
  deserialize: _blockHeaderEntityDeserialize,
  deserializeProp: _blockHeaderEntityDeserializeProp,
  idName: r'id',
  indexes: {
    r'height': IndexSchema(
      id: 3439375685700528633,
      name: r'height',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'height',
          type: IndexType.value,
          caseSensitive: false,
        )
      ],
    ),
    r'hash': IndexSchema(
      id: -7973251393006690288,
      name: r'hash',
      unique: true,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'hash',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'isOrphaned': IndexSchema(
      id: 4055793748590744630,
      name: r'isOrphaned',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'isOrphaned',
          type: IndexType.value,
          caseSensitive: false,
        )
      ],
    )
  },
  links: {},
  embeddedSchemas: {},
  getId: _blockHeaderEntityGetId,
  getLinks: _blockHeaderEntityGetLinks,
  attach: _blockHeaderEntityAttach,
  version: '3.1.0+1',
);

int _blockHeaderEntityEstimateSize(
  BlockHeaderEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.hash.length * 3;
  bytesCount += 3 + object.merkleRoot.length * 3;
  bytesCount += 3 + object.prevBlockHash.length * 3;
  return bytesCount;
}

void _blockHeaderEntitySerialize(
  BlockHeaderEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeLong(offsets[0], object.bits);
  writer.writeString(offsets[1], object.hash);
  writer.writeLong(offsets[2], object.height);
  writer.writeBool(offsets[3], object.isOrphaned);
  writer.writeString(offsets[4], object.merkleRoot);
  writer.writeLong(offsets[5], object.nonce);
  writer.writeString(offsets[6], object.prevBlockHash);
  writer.writeDateTime(offsets[7], object.storedAt);
  writer.writeLong(offsets[8], object.timestamp);
  writer.writeLong(offsets[9], object.version);
}

BlockHeaderEntity _blockHeaderEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = BlockHeaderEntity();
  object.bits = reader.readLong(offsets[0]);
  object.hash = reader.readString(offsets[1]);
  object.height = reader.readLong(offsets[2]);
  object.id = id;
  object.isOrphaned = reader.readBool(offsets[3]);
  object.merkleRoot = reader.readString(offsets[4]);
  object.nonce = reader.readLong(offsets[5]);
  object.prevBlockHash = reader.readString(offsets[6]);
  object.storedAt = reader.readDateTime(offsets[7]);
  object.timestamp = reader.readLong(offsets[8]);
  object.version = reader.readLong(offsets[9]);
  return object;
}

P _blockHeaderEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readLong(offset)) as P;
    case 1:
      return (reader.readString(offset)) as P;
    case 2:
      return (reader.readLong(offset)) as P;
    case 3:
      return (reader.readBool(offset)) as P;
    case 4:
      return (reader.readString(offset)) as P;
    case 5:
      return (reader.readLong(offset)) as P;
    case 6:
      return (reader.readString(offset)) as P;
    case 7:
      return (reader.readDateTime(offset)) as P;
    case 8:
      return (reader.readLong(offset)) as P;
    case 9:
      return (reader.readLong(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _blockHeaderEntityGetId(BlockHeaderEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _blockHeaderEntityGetLinks(
    BlockHeaderEntity object) {
  return [];
}

void _blockHeaderEntityAttach(
    IsarCollection<dynamic> col, Id id, BlockHeaderEntity object) {
  object.id = id;
}

extension BlockHeaderEntityByIndex on IsarCollection<BlockHeaderEntity> {
  Future<BlockHeaderEntity?> getByHash(String hash) {
    return getByIndex(r'hash', [hash]);
  }

  BlockHeaderEntity? getByHashSync(String hash) {
    return getByIndexSync(r'hash', [hash]);
  }

  Future<bool> deleteByHash(String hash) {
    return deleteByIndex(r'hash', [hash]);
  }

  bool deleteByHashSync(String hash) {
    return deleteByIndexSync(r'hash', [hash]);
  }

  Future<List<BlockHeaderEntity?>> getAllByHash(List<String> hashValues) {
    final values = hashValues.map((e) => [e]).toList();
    return getAllByIndex(r'hash', values);
  }

  List<BlockHeaderEntity?> getAllByHashSync(List<String> hashValues) {
    final values = hashValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'hash', values);
  }

  Future<int> deleteAllByHash(List<String> hashValues) {
    final values = hashValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'hash', values);
  }

  int deleteAllByHashSync(List<String> hashValues) {
    final values = hashValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'hash', values);
  }

  Future<Id> putByHash(BlockHeaderEntity object) {
    return putByIndex(r'hash', object);
  }

  Id putByHashSync(BlockHeaderEntity object, {bool saveLinks = true}) {
    return putByIndexSync(r'hash', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByHash(List<BlockHeaderEntity> objects) {
    return putAllByIndex(r'hash', objects);
  }

  List<Id> putAllByHashSync(List<BlockHeaderEntity> objects,
      {bool saveLinks = true}) {
    return putAllByIndexSync(r'hash', objects, saveLinks: saveLinks);
  }
}

extension BlockHeaderEntityQueryWhereSort
    on QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QWhere> {
  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhere> anyHeight() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'height'),
      );
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhere>
      anyIsOrphaned() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'isOrphaned'),
      );
    });
  }
}

extension BlockHeaderEntityQueryWhere
    on QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QWhereClause> {
  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhereClause>
      idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhereClause>
      idNotEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhereClause>
      idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhereClause>
      idLessThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhereClause>
      idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: lowerId,
        includeLower: includeLower,
        upper: upperId,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhereClause>
      heightEqualTo(int height) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'height',
        value: [height],
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhereClause>
      heightNotEqualTo(int height) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'height',
              lower: [],
              upper: [height],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'height',
              lower: [height],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'height',
              lower: [height],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'height',
              lower: [],
              upper: [height],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhereClause>
      heightGreaterThan(
    int height, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'height',
        lower: [height],
        includeLower: include,
        upper: [],
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhereClause>
      heightLessThan(
    int height, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'height',
        lower: [],
        upper: [height],
        includeUpper: include,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhereClause>
      heightBetween(
    int lowerHeight,
    int upperHeight, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'height',
        lower: [lowerHeight],
        includeLower: includeLower,
        upper: [upperHeight],
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhereClause>
      hashEqualTo(String hash) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'hash',
        value: [hash],
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhereClause>
      hashNotEqualTo(String hash) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'hash',
              lower: [],
              upper: [hash],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'hash',
              lower: [hash],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'hash',
              lower: [hash],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'hash',
              lower: [],
              upper: [hash],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhereClause>
      isOrphanedEqualTo(bool isOrphaned) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'isOrphaned',
        value: [isOrphaned],
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterWhereClause>
      isOrphanedNotEqualTo(bool isOrphaned) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'isOrphaned',
              lower: [],
              upper: [isOrphaned],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'isOrphaned',
              lower: [isOrphaned],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'isOrphaned',
              lower: [isOrphaned],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'isOrphaned',
              lower: [],
              upper: [isOrphaned],
              includeUpper: false,
            ));
      }
    });
  }
}

extension BlockHeaderEntityQueryFilter
    on QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QFilterCondition> {
  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      bitsEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'bits',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      bitsGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'bits',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      bitsLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'bits',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      bitsBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'bits',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      hashEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'hash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      hashGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'hash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      hashLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'hash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      hashBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'hash',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      hashStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'hash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      hashEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'hash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      hashContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'hash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      hashMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'hash',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      hashIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'hash',
        value: '',
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      hashIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'hash',
        value: '',
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      heightEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'height',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      heightGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'height',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      heightLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'height',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      heightBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'height',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      idGreaterThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'id',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      isOrphanedEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'isOrphaned',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      merkleRootEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'merkleRoot',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      merkleRootGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'merkleRoot',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      merkleRootLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'merkleRoot',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      merkleRootBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'merkleRoot',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      merkleRootStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'merkleRoot',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      merkleRootEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'merkleRoot',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      merkleRootContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'merkleRoot',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      merkleRootMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'merkleRoot',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      merkleRootIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'merkleRoot',
        value: '',
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      merkleRootIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'merkleRoot',
        value: '',
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      nonceEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'nonce',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      nonceGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'nonce',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      nonceLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'nonce',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      nonceBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'nonce',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      prevBlockHashEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'prevBlockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      prevBlockHashGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'prevBlockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      prevBlockHashLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'prevBlockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      prevBlockHashBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'prevBlockHash',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      prevBlockHashStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'prevBlockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      prevBlockHashEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'prevBlockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      prevBlockHashContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'prevBlockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      prevBlockHashMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'prevBlockHash',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      prevBlockHashIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'prevBlockHash',
        value: '',
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      prevBlockHashIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'prevBlockHash',
        value: '',
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      storedAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'storedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      storedAtGreaterThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'storedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      storedAtLessThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'storedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      storedAtBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'storedAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      timestampEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'timestamp',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      timestampGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'timestamp',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      timestampLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'timestamp',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      timestampBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'timestamp',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      versionEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'version',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      versionGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'version',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      versionLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'version',
        value: value,
      ));
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterFilterCondition>
      versionBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'version',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }
}

extension BlockHeaderEntityQueryObject
    on QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QFilterCondition> {}

extension BlockHeaderEntityQueryLinks
    on QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QFilterCondition> {}

extension BlockHeaderEntityQuerySortBy
    on QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QSortBy> {
  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByBits() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bits', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByBitsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bits', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByHash() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hash', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByHashDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hash', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByHeight() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'height', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByHeightDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'height', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByIsOrphaned() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isOrphaned', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByIsOrphanedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isOrphaned', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByMerkleRoot() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'merkleRoot', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByMerkleRootDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'merkleRoot', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByNonce() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'nonce', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByNonceDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'nonce', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByPrevBlockHash() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'prevBlockHash', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByPrevBlockHashDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'prevBlockHash', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByStoredAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'storedAt', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByStoredAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'storedAt', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByTimestamp() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'timestamp', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByTimestampDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'timestamp', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'version', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      sortByVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'version', Sort.desc);
    });
  }
}

extension BlockHeaderEntityQuerySortThenBy
    on QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QSortThenBy> {
  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByBits() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bits', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByBitsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bits', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByHash() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hash', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByHashDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hash', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByHeight() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'height', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByHeightDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'height', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByIsOrphaned() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isOrphaned', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByIsOrphanedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isOrphaned', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByMerkleRoot() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'merkleRoot', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByMerkleRootDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'merkleRoot', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByNonce() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'nonce', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByNonceDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'nonce', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByPrevBlockHash() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'prevBlockHash', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByPrevBlockHashDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'prevBlockHash', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByStoredAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'storedAt', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByStoredAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'storedAt', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByTimestamp() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'timestamp', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByTimestampDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'timestamp', Sort.desc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'version', Sort.asc);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QAfterSortBy>
      thenByVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'version', Sort.desc);
    });
  }
}

extension BlockHeaderEntityQueryWhereDistinct
    on QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QDistinct> {
  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QDistinct>
      distinctByBits() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'bits');
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QDistinct> distinctByHash(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'hash', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QDistinct>
      distinctByHeight() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'height');
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QDistinct>
      distinctByIsOrphaned() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'isOrphaned');
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QDistinct>
      distinctByMerkleRoot({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'merkleRoot', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QDistinct>
      distinctByNonce() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'nonce');
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QDistinct>
      distinctByPrevBlockHash({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'prevBlockHash',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QDistinct>
      distinctByStoredAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'storedAt');
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QDistinct>
      distinctByTimestamp() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'timestamp');
    });
  }

  QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QDistinct>
      distinctByVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'version');
    });
  }
}

extension BlockHeaderEntityQueryProperty
    on QueryBuilder<BlockHeaderEntity, BlockHeaderEntity, QQueryProperty> {
  QueryBuilder<BlockHeaderEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<BlockHeaderEntity, int, QQueryOperations> bitsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'bits');
    });
  }

  QueryBuilder<BlockHeaderEntity, String, QQueryOperations> hashProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'hash');
    });
  }

  QueryBuilder<BlockHeaderEntity, int, QQueryOperations> heightProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'height');
    });
  }

  QueryBuilder<BlockHeaderEntity, bool, QQueryOperations> isOrphanedProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'isOrphaned');
    });
  }

  QueryBuilder<BlockHeaderEntity, String, QQueryOperations>
      merkleRootProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'merkleRoot');
    });
  }

  QueryBuilder<BlockHeaderEntity, int, QQueryOperations> nonceProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'nonce');
    });
  }

  QueryBuilder<BlockHeaderEntity, String, QQueryOperations>
      prevBlockHashProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'prevBlockHash');
    });
  }

  QueryBuilder<BlockHeaderEntity, DateTime, QQueryOperations>
      storedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'storedAt');
    });
  }

  QueryBuilder<BlockHeaderEntity, int, QQueryOperations> timestampProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'timestamp');
    });
  }

  QueryBuilder<BlockHeaderEntity, int, QQueryOperations> versionProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'version');
    });
  }
}

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetMerkleProofEntityCollection on Isar {
  IsarCollection<MerkleProofEntity> get merkleProofEntitys => this.collection();
}

const MerkleProofEntitySchema = CollectionSchema(
  name: r'MerkleProofEntity',
  id: -8220347419910625714,
  properties: {
    r'blockHash': PropertySchema(
      id: 0,
      name: r'blockHash',
      type: IsarType.string,
    ),
    r'blockHeight': PropertySchema(
      id: 1,
      name: r'blockHeight',
      type: IsarType.long,
    ),
    r'createdAt': PropertySchema(
      id: 2,
      name: r'createdAt',
      type: IsarType.dateTime,
    ),
    r'merkleProofJson': PropertySchema(
      id: 3,
      name: r'merkleProofJson',
      type: IsarType.string,
    ),
    r'position': PropertySchema(
      id: 4,
      name: r'position',
      type: IsarType.long,
    ),
    r'txid': PropertySchema(
      id: 5,
      name: r'txid',
      type: IsarType.string,
    )
  },
  estimateSize: _merkleProofEntityEstimateSize,
  serialize: _merkleProofEntitySerialize,
  deserialize: _merkleProofEntityDeserialize,
  deserializeProp: _merkleProofEntityDeserializeProp,
  idName: r'id',
  indexes: {
    r'txid': IndexSchema(
      id: 7339874292043634331,
      name: r'txid',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'txid',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'blockHash': IndexSchema(
      id: -697305699729616785,
      name: r'blockHash',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'blockHash',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    )
  },
  links: {},
  embeddedSchemas: {},
  getId: _merkleProofEntityGetId,
  getLinks: _merkleProofEntityGetLinks,
  attach: _merkleProofEntityAttach,
  version: '3.1.0+1',
);

int _merkleProofEntityEstimateSize(
  MerkleProofEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.blockHash.length * 3;
  bytesCount += 3 + object.merkleProofJson.length * 3;
  bytesCount += 3 + object.txid.length * 3;
  return bytesCount;
}

void _merkleProofEntitySerialize(
  MerkleProofEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.blockHash);
  writer.writeLong(offsets[1], object.blockHeight);
  writer.writeDateTime(offsets[2], object.createdAt);
  writer.writeString(offsets[3], object.merkleProofJson);
  writer.writeLong(offsets[4], object.position);
  writer.writeString(offsets[5], object.txid);
}

MerkleProofEntity _merkleProofEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = MerkleProofEntity();
  object.blockHash = reader.readString(offsets[0]);
  object.blockHeight = reader.readLong(offsets[1]);
  object.createdAt = reader.readDateTime(offsets[2]);
  object.id = id;
  object.merkleProofJson = reader.readString(offsets[3]);
  object.position = reader.readLong(offsets[4]);
  object.txid = reader.readString(offsets[5]);
  return object;
}

P _merkleProofEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readString(offset)) as P;
    case 1:
      return (reader.readLong(offset)) as P;
    case 2:
      return (reader.readDateTime(offset)) as P;
    case 3:
      return (reader.readString(offset)) as P;
    case 4:
      return (reader.readLong(offset)) as P;
    case 5:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _merkleProofEntityGetId(MerkleProofEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _merkleProofEntityGetLinks(
    MerkleProofEntity object) {
  return [];
}

void _merkleProofEntityAttach(
    IsarCollection<dynamic> col, Id id, MerkleProofEntity object) {
  object.id = id;
}

extension MerkleProofEntityQueryWhereSort
    on QueryBuilder<MerkleProofEntity, MerkleProofEntity, QWhere> {
  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension MerkleProofEntityQueryWhere
    on QueryBuilder<MerkleProofEntity, MerkleProofEntity, QWhereClause> {
  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterWhereClause>
      idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterWhereClause>
      idNotEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterWhereClause>
      idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterWhereClause>
      idLessThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterWhereClause>
      idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: lowerId,
        includeLower: includeLower,
        upper: upperId,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterWhereClause>
      txidEqualTo(String txid) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'txid',
        value: [txid],
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterWhereClause>
      txidNotEqualTo(String txid) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [],
              upper: [txid],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [txid],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [txid],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [],
              upper: [txid],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterWhereClause>
      blockHashEqualTo(String blockHash) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'blockHash',
        value: [blockHash],
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterWhereClause>
      blockHashNotEqualTo(String blockHash) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'blockHash',
              lower: [],
              upper: [blockHash],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'blockHash',
              lower: [blockHash],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'blockHash',
              lower: [blockHash],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'blockHash',
              lower: [],
              upper: [blockHash],
              includeUpper: false,
            ));
      }
    });
  }
}

extension MerkleProofEntityQueryFilter
    on QueryBuilder<MerkleProofEntity, MerkleProofEntity, QFilterCondition> {
  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      blockHashEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'blockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      blockHashGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'blockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      blockHashLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'blockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      blockHashBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'blockHash',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      blockHashStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'blockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      blockHashEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'blockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      blockHashContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'blockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      blockHashMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'blockHash',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      blockHashIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'blockHash',
        value: '',
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      blockHashIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'blockHash',
        value: '',
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      blockHeightEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'blockHeight',
        value: value,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      blockHeightGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'blockHeight',
        value: value,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      blockHeightLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'blockHeight',
        value: value,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      blockHeightBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'blockHeight',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      createdAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      createdAtGreaterThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      createdAtLessThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      createdAtBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'createdAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      idGreaterThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'id',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      merkleProofJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'merkleProofJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      merkleProofJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'merkleProofJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      merkleProofJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'merkleProofJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      merkleProofJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'merkleProofJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      merkleProofJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'merkleProofJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      merkleProofJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'merkleProofJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      merkleProofJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'merkleProofJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      merkleProofJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'merkleProofJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      merkleProofJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'merkleProofJson',
        value: '',
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      merkleProofJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'merkleProofJson',
        value: '',
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      positionEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'position',
        value: value,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      positionGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'position',
        value: value,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      positionLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'position',
        value: value,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      positionBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'position',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      txidEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      txidGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      txidLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      txidBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'txid',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      txidStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      txidEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      txidContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      txidMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'txid',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      txidIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'txid',
        value: '',
      ));
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterFilterCondition>
      txidIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'txid',
        value: '',
      ));
    });
  }
}

extension MerkleProofEntityQueryObject
    on QueryBuilder<MerkleProofEntity, MerkleProofEntity, QFilterCondition> {}

extension MerkleProofEntityQueryLinks
    on QueryBuilder<MerkleProofEntity, MerkleProofEntity, QFilterCondition> {}

extension MerkleProofEntityQuerySortBy
    on QueryBuilder<MerkleProofEntity, MerkleProofEntity, QSortBy> {
  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      sortByBlockHash() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHash', Sort.asc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      sortByBlockHashDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHash', Sort.desc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      sortByBlockHeight() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHeight', Sort.asc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      sortByBlockHeightDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHeight', Sort.desc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      sortByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      sortByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      sortByMerkleProofJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'merkleProofJson', Sort.asc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      sortByMerkleProofJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'merkleProofJson', Sort.desc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      sortByPosition() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'position', Sort.asc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      sortByPositionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'position', Sort.desc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      sortByTxid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.asc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      sortByTxidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.desc);
    });
  }
}

extension MerkleProofEntityQuerySortThenBy
    on QueryBuilder<MerkleProofEntity, MerkleProofEntity, QSortThenBy> {
  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      thenByBlockHash() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHash', Sort.asc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      thenByBlockHashDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHash', Sort.desc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      thenByBlockHeight() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHeight', Sort.asc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      thenByBlockHeightDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHeight', Sort.desc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      thenByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      thenByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      thenByMerkleProofJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'merkleProofJson', Sort.asc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      thenByMerkleProofJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'merkleProofJson', Sort.desc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      thenByPosition() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'position', Sort.asc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      thenByPositionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'position', Sort.desc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      thenByTxid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.asc);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QAfterSortBy>
      thenByTxidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.desc);
    });
  }
}

extension MerkleProofEntityQueryWhereDistinct
    on QueryBuilder<MerkleProofEntity, MerkleProofEntity, QDistinct> {
  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QDistinct>
      distinctByBlockHash({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'blockHash', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QDistinct>
      distinctByBlockHeight() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'blockHeight');
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QDistinct>
      distinctByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'createdAt');
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QDistinct>
      distinctByMerkleProofJson({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'merkleProofJson',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QDistinct>
      distinctByPosition() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'position');
    });
  }

  QueryBuilder<MerkleProofEntity, MerkleProofEntity, QDistinct> distinctByTxid(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'txid', caseSensitive: caseSensitive);
    });
  }
}

extension MerkleProofEntityQueryProperty
    on QueryBuilder<MerkleProofEntity, MerkleProofEntity, QQueryProperty> {
  QueryBuilder<MerkleProofEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<MerkleProofEntity, String, QQueryOperations>
      blockHashProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'blockHash');
    });
  }

  QueryBuilder<MerkleProofEntity, int, QQueryOperations> blockHeightProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'blockHeight');
    });
  }

  QueryBuilder<MerkleProofEntity, DateTime, QQueryOperations>
      createdAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'createdAt');
    });
  }

  QueryBuilder<MerkleProofEntity, String, QQueryOperations>
      merkleProofJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'merkleProofJson');
    });
  }

  QueryBuilder<MerkleProofEntity, int, QQueryOperations> positionProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'position');
    });
  }

  QueryBuilder<MerkleProofEntity, String, QQueryOperations> txidProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'txid');
    });
  }
}

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetWalletEventEntityCollection on Isar {
  IsarCollection<WalletEventEntity> get walletEventEntitys => this.collection();
}

const WalletEventEntitySchema = CollectionSchema(
  name: r'WalletEventEntity',
  id: -858548467826076375,
  properties: {
    r'aggregateVersion': PropertySchema(
      id: 0,
      name: r'aggregateVersion',
      type: IsarType.long,
    ),
    r'eventData': PropertySchema(
      id: 1,
      name: r'eventData',
      type: IsarType.string,
    ),
    r'eventType': PropertySchema(
      id: 2,
      name: r'eventType',
      type: IsarType.string,
    ),
    r'timestamp': PropertySchema(
      id: 3,
      name: r'timestamp',
      type: IsarType.dateTime,
    ),
    r'version': PropertySchema(
      id: 4,
      name: r'version',
      type: IsarType.long,
    ),
    r'walletId': PropertySchema(
      id: 5,
      name: r'walletId',
      type: IsarType.string,
    )
  },
  estimateSize: _walletEventEntityEstimateSize,
  serialize: _walletEventEntitySerialize,
  deserialize: _walletEventEntityDeserialize,
  deserializeProp: _walletEventEntityDeserializeProp,
  idName: r'id',
  indexes: {
    r'walletId': IndexSchema(
      id: -1783113319798776304,
      name: r'walletId',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'walletId',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'version': IndexSchema(
      id: -3425991338577364869,
      name: r'version',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'version',
          type: IndexType.value,
          caseSensitive: false,
        )
      ],
    ),
    r'timestamp': IndexSchema(
      id: 1852253767416892198,
      name: r'timestamp',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'timestamp',
          type: IndexType.value,
          caseSensitive: false,
        )
      ],
    )
  },
  links: {},
  embeddedSchemas: {},
  getId: _walletEventEntityGetId,
  getLinks: _walletEventEntityGetLinks,
  attach: _walletEventEntityAttach,
  version: '3.1.0+1',
);

int _walletEventEntityEstimateSize(
  WalletEventEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.eventData.length * 3;
  bytesCount += 3 + object.eventType.length * 3;
  bytesCount += 3 + object.walletId.length * 3;
  return bytesCount;
}

void _walletEventEntitySerialize(
  WalletEventEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeLong(offsets[0], object.aggregateVersion);
  writer.writeString(offsets[1], object.eventData);
  writer.writeString(offsets[2], object.eventType);
  writer.writeDateTime(offsets[3], object.timestamp);
  writer.writeLong(offsets[4], object.version);
  writer.writeString(offsets[5], object.walletId);
}

WalletEventEntity _walletEventEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = WalletEventEntity();
  object.aggregateVersion = reader.readLong(offsets[0]);
  object.eventData = reader.readString(offsets[1]);
  object.eventType = reader.readString(offsets[2]);
  object.id = id;
  object.timestamp = reader.readDateTime(offsets[3]);
  object.version = reader.readLong(offsets[4]);
  object.walletId = reader.readString(offsets[5]);
  return object;
}

P _walletEventEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readLong(offset)) as P;
    case 1:
      return (reader.readString(offset)) as P;
    case 2:
      return (reader.readString(offset)) as P;
    case 3:
      return (reader.readDateTime(offset)) as P;
    case 4:
      return (reader.readLong(offset)) as P;
    case 5:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _walletEventEntityGetId(WalletEventEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _walletEventEntityGetLinks(
    WalletEventEntity object) {
  return [];
}

void _walletEventEntityAttach(
    IsarCollection<dynamic> col, Id id, WalletEventEntity object) {
  object.id = id;
}

extension WalletEventEntityQueryWhereSort
    on QueryBuilder<WalletEventEntity, WalletEventEntity, QWhere> {
  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhere> anyVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'version'),
      );
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhere>
      anyTimestamp() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'timestamp'),
      );
    });
  }
}

extension WalletEventEntityQueryWhere
    on QueryBuilder<WalletEventEntity, WalletEventEntity, QWhereClause> {
  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      idNotEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      idLessThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: lowerId,
        includeLower: includeLower,
        upper: upperId,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      walletIdEqualTo(String walletId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'walletId',
        value: [walletId],
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      walletIdNotEqualTo(String walletId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [],
              upper: [walletId],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [walletId],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [walletId],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [],
              upper: [walletId],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      versionEqualTo(int version) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'version',
        value: [version],
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      versionNotEqualTo(int version) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'version',
              lower: [],
              upper: [version],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'version',
              lower: [version],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'version',
              lower: [version],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'version',
              lower: [],
              upper: [version],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      versionGreaterThan(
    int version, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'version',
        lower: [version],
        includeLower: include,
        upper: [],
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      versionLessThan(
    int version, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'version',
        lower: [],
        upper: [version],
        includeUpper: include,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      versionBetween(
    int lowerVersion,
    int upperVersion, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'version',
        lower: [lowerVersion],
        includeLower: includeLower,
        upper: [upperVersion],
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      timestampEqualTo(DateTime timestamp) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'timestamp',
        value: [timestamp],
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      timestampNotEqualTo(DateTime timestamp) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'timestamp',
              lower: [],
              upper: [timestamp],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'timestamp',
              lower: [timestamp],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'timestamp',
              lower: [timestamp],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'timestamp',
              lower: [],
              upper: [timestamp],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      timestampGreaterThan(
    DateTime timestamp, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'timestamp',
        lower: [timestamp],
        includeLower: include,
        upper: [],
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      timestampLessThan(
    DateTime timestamp, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'timestamp',
        lower: [],
        upper: [timestamp],
        includeUpper: include,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterWhereClause>
      timestampBetween(
    DateTime lowerTimestamp,
    DateTime upperTimestamp, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'timestamp',
        lower: [lowerTimestamp],
        includeLower: includeLower,
        upper: [upperTimestamp],
        includeUpper: includeUpper,
      ));
    });
  }
}

extension WalletEventEntityQueryFilter
    on QueryBuilder<WalletEventEntity, WalletEventEntity, QFilterCondition> {
  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      aggregateVersionEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'aggregateVersion',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      aggregateVersionGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'aggregateVersion',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      aggregateVersionLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'aggregateVersion',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      aggregateVersionBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'aggregateVersion',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventDataEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'eventData',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventDataGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'eventData',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventDataLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'eventData',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventDataBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'eventData',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventDataStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'eventData',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventDataEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'eventData',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventDataContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'eventData',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventDataMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'eventData',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventDataIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'eventData',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventDataIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'eventData',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventTypeEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'eventType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventTypeGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'eventType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventTypeLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'eventType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventTypeBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'eventType',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventTypeStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'eventType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventTypeEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'eventType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventTypeContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'eventType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventTypeMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'eventType',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventTypeIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'eventType',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      eventTypeIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'eventType',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      idGreaterThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'id',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      timestampEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'timestamp',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      timestampGreaterThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'timestamp',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      timestampLessThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'timestamp',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      timestampBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'timestamp',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      versionEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'version',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      versionGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'version',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      versionLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'version',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      versionBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'version',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      walletIdEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      walletIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      walletIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      walletIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'walletId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      walletIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      walletIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      walletIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      walletIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'walletId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      walletIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterFilterCondition>
      walletIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'walletId',
        value: '',
      ));
    });
  }
}

extension WalletEventEntityQueryObject
    on QueryBuilder<WalletEventEntity, WalletEventEntity, QFilterCondition> {}

extension WalletEventEntityQueryLinks
    on QueryBuilder<WalletEventEntity, WalletEventEntity, QFilterCondition> {}

extension WalletEventEntityQuerySortBy
    on QueryBuilder<WalletEventEntity, WalletEventEntity, QSortBy> {
  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      sortByAggregateVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'aggregateVersion', Sort.asc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      sortByAggregateVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'aggregateVersion', Sort.desc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      sortByEventData() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'eventData', Sort.asc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      sortByEventDataDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'eventData', Sort.desc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      sortByEventType() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'eventType', Sort.asc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      sortByEventTypeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'eventType', Sort.desc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      sortByTimestamp() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'timestamp', Sort.asc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      sortByTimestampDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'timestamp', Sort.desc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      sortByVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'version', Sort.asc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      sortByVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'version', Sort.desc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      sortByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      sortByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }
}

extension WalletEventEntityQuerySortThenBy
    on QueryBuilder<WalletEventEntity, WalletEventEntity, QSortThenBy> {
  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      thenByAggregateVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'aggregateVersion', Sort.asc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      thenByAggregateVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'aggregateVersion', Sort.desc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      thenByEventData() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'eventData', Sort.asc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      thenByEventDataDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'eventData', Sort.desc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      thenByEventType() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'eventType', Sort.asc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      thenByEventTypeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'eventType', Sort.desc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      thenByTimestamp() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'timestamp', Sort.asc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      thenByTimestampDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'timestamp', Sort.desc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      thenByVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'version', Sort.asc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      thenByVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'version', Sort.desc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      thenByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QAfterSortBy>
      thenByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }
}

extension WalletEventEntityQueryWhereDistinct
    on QueryBuilder<WalletEventEntity, WalletEventEntity, QDistinct> {
  QueryBuilder<WalletEventEntity, WalletEventEntity, QDistinct>
      distinctByAggregateVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'aggregateVersion');
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QDistinct>
      distinctByEventData({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'eventData', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QDistinct>
      distinctByEventType({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'eventType', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QDistinct>
      distinctByTimestamp() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'timestamp');
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QDistinct>
      distinctByVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'version');
    });
  }

  QueryBuilder<WalletEventEntity, WalletEventEntity, QDistinct>
      distinctByWalletId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'walletId', caseSensitive: caseSensitive);
    });
  }
}

extension WalletEventEntityQueryProperty
    on QueryBuilder<WalletEventEntity, WalletEventEntity, QQueryProperty> {
  QueryBuilder<WalletEventEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<WalletEventEntity, int, QQueryOperations>
      aggregateVersionProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'aggregateVersion');
    });
  }

  QueryBuilder<WalletEventEntity, String, QQueryOperations>
      eventDataProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'eventData');
    });
  }

  QueryBuilder<WalletEventEntity, String, QQueryOperations>
      eventTypeProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'eventType');
    });
  }

  QueryBuilder<WalletEventEntity, DateTime, QQueryOperations>
      timestampProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'timestamp');
    });
  }

  QueryBuilder<WalletEventEntity, int, QQueryOperations> versionProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'version');
    });
  }

  QueryBuilder<WalletEventEntity, String, QQueryOperations> walletIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'walletId');
    });
  }
}

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetBitcoinUtxoEntityCollection on Isar {
  IsarCollection<BitcoinUtxoEntity> get bitcoinUtxoEntitys => this.collection();
}

const BitcoinUtxoEntitySchema = CollectionSchema(
  name: r'BitcoinUtxoEntity',
  id: -5888046012732144981,
  properties: {
    r'address': PropertySchema(
      id: 0,
      name: r'address',
      type: IsarType.string,
    ),
    r'blockHeight': PropertySchema(
      id: 1,
      name: r'blockHeight',
      type: IsarType.long,
    ),
    r'category': PropertySchema(
      id: 2,
      name: r'category',
      type: IsarType.string,
    ),
    r'confirmations': PropertySchema(
      id: 3,
      name: r'confirmations',
      type: IsarType.long,
    ),
    r'createdAt': PropertySchema(
      id: 4,
      name: r'createdAt',
      type: IsarType.dateTime,
    ),
    r'isSpendable': PropertySchema(
      id: 5,
      name: r'isSpendable',
      type: IsarType.bool,
    ),
    r'satoshis': PropertySchema(
      id: 6,
      name: r'satoshis',
      type: IsarType.string,
    ),
    r'scriptPubKey': PropertySchema(
      id: 7,
      name: r'scriptPubKey',
      type: IsarType.string,
    ),
    r'scriptType': PropertySchema(
      id: 8,
      name: r'scriptType',
      type: IsarType.string,
    ),
    r'spentAt': PropertySchema(
      id: 9,
      name: r'spentAt',
      type: IsarType.dateTime,
    ),
    r'spentInTxId': PropertySchema(
      id: 10,
      name: r'spentInTxId',
      type: IsarType.string,
    ),
    r'status': PropertySchema(
      id: 11,
      name: r'status',
      type: IsarType.string,
    ),
    r'txid': PropertySchema(
      id: 12,
      name: r'txid',
      type: IsarType.string,
    ),
    r'utxoKey': PropertySchema(
      id: 13,
      name: r'utxoKey',
      type: IsarType.string,
    ),
    r'vout': PropertySchema(
      id: 14,
      name: r'vout',
      type: IsarType.long,
    ),
    r'walletId': PropertySchema(
      id: 15,
      name: r'walletId',
      type: IsarType.string,
    )
  },
  estimateSize: _bitcoinUtxoEntityEstimateSize,
  serialize: _bitcoinUtxoEntitySerialize,
  deserialize: _bitcoinUtxoEntityDeserialize,
  deserializeProp: _bitcoinUtxoEntityDeserializeProp,
  idName: r'id',
  indexes: {
    r'walletId': IndexSchema(
      id: -1783113319798776304,
      name: r'walletId',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'walletId',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'txid': IndexSchema(
      id: 7339874292043634331,
      name: r'txid',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'txid',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'utxoKey': IndexSchema(
      id: 224192052285061779,
      name: r'utxoKey',
      unique: true,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'utxoKey',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'status': IndexSchema(
      id: -107785170620420283,
      name: r'status',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'status',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    )
  },
  links: {},
  embeddedSchemas: {},
  getId: _bitcoinUtxoEntityGetId,
  getLinks: _bitcoinUtxoEntityGetLinks,
  attach: _bitcoinUtxoEntityAttach,
  version: '3.1.0+1',
);

int _bitcoinUtxoEntityEstimateSize(
  BitcoinUtxoEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  {
    final value = object.address;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.category.length * 3;
  bytesCount += 3 + object.satoshis.length * 3;
  bytesCount += 3 + object.scriptPubKey.length * 3;
  bytesCount += 3 + object.scriptType.length * 3;
  {
    final value = object.spentInTxId;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.status.length * 3;
  bytesCount += 3 + object.txid.length * 3;
  bytesCount += 3 + object.utxoKey.length * 3;
  bytesCount += 3 + object.walletId.length * 3;
  return bytesCount;
}

void _bitcoinUtxoEntitySerialize(
  BitcoinUtxoEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.address);
  writer.writeLong(offsets[1], object.blockHeight);
  writer.writeString(offsets[2], object.category);
  writer.writeLong(offsets[3], object.confirmations);
  writer.writeDateTime(offsets[4], object.createdAt);
  writer.writeBool(offsets[5], object.isSpendable);
  writer.writeString(offsets[6], object.satoshis);
  writer.writeString(offsets[7], object.scriptPubKey);
  writer.writeString(offsets[8], object.scriptType);
  writer.writeDateTime(offsets[9], object.spentAt);
  writer.writeString(offsets[10], object.spentInTxId);
  writer.writeString(offsets[11], object.status);
  writer.writeString(offsets[12], object.txid);
  writer.writeString(offsets[13], object.utxoKey);
  writer.writeLong(offsets[14], object.vout);
  writer.writeString(offsets[15], object.walletId);
}

BitcoinUtxoEntity _bitcoinUtxoEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = BitcoinUtxoEntity();
  object.address = reader.readStringOrNull(offsets[0]);
  object.blockHeight = reader.readLongOrNull(offsets[1]);
  object.category = reader.readString(offsets[2]);
  object.confirmations = reader.readLong(offsets[3]);
  object.createdAt = reader.readDateTime(offsets[4]);
  object.id = id;
  object.isSpendable = reader.readBool(offsets[5]);
  object.satoshis = reader.readString(offsets[6]);
  object.scriptPubKey = reader.readString(offsets[7]);
  object.scriptType = reader.readString(offsets[8]);
  object.spentAt = reader.readDateTimeOrNull(offsets[9]);
  object.spentInTxId = reader.readStringOrNull(offsets[10]);
  object.status = reader.readString(offsets[11]);
  object.txid = reader.readString(offsets[12]);
  object.utxoKey = reader.readString(offsets[13]);
  object.vout = reader.readLong(offsets[14]);
  object.walletId = reader.readString(offsets[15]);
  return object;
}

P _bitcoinUtxoEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readStringOrNull(offset)) as P;
    case 1:
      return (reader.readLongOrNull(offset)) as P;
    case 2:
      return (reader.readString(offset)) as P;
    case 3:
      return (reader.readLong(offset)) as P;
    case 4:
      return (reader.readDateTime(offset)) as P;
    case 5:
      return (reader.readBool(offset)) as P;
    case 6:
      return (reader.readString(offset)) as P;
    case 7:
      return (reader.readString(offset)) as P;
    case 8:
      return (reader.readString(offset)) as P;
    case 9:
      return (reader.readDateTimeOrNull(offset)) as P;
    case 10:
      return (reader.readStringOrNull(offset)) as P;
    case 11:
      return (reader.readString(offset)) as P;
    case 12:
      return (reader.readString(offset)) as P;
    case 13:
      return (reader.readString(offset)) as P;
    case 14:
      return (reader.readLong(offset)) as P;
    case 15:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _bitcoinUtxoEntityGetId(BitcoinUtxoEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _bitcoinUtxoEntityGetLinks(
    BitcoinUtxoEntity object) {
  return [];
}

void _bitcoinUtxoEntityAttach(
    IsarCollection<dynamic> col, Id id, BitcoinUtxoEntity object) {
  object.id = id;
}

extension BitcoinUtxoEntityByIndex on IsarCollection<BitcoinUtxoEntity> {
  Future<BitcoinUtxoEntity?> getByUtxoKey(String utxoKey) {
    return getByIndex(r'utxoKey', [utxoKey]);
  }

  BitcoinUtxoEntity? getByUtxoKeySync(String utxoKey) {
    return getByIndexSync(r'utxoKey', [utxoKey]);
  }

  Future<bool> deleteByUtxoKey(String utxoKey) {
    return deleteByIndex(r'utxoKey', [utxoKey]);
  }

  bool deleteByUtxoKeySync(String utxoKey) {
    return deleteByIndexSync(r'utxoKey', [utxoKey]);
  }

  Future<List<BitcoinUtxoEntity?>> getAllByUtxoKey(List<String> utxoKeyValues) {
    final values = utxoKeyValues.map((e) => [e]).toList();
    return getAllByIndex(r'utxoKey', values);
  }

  List<BitcoinUtxoEntity?> getAllByUtxoKeySync(List<String> utxoKeyValues) {
    final values = utxoKeyValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'utxoKey', values);
  }

  Future<int> deleteAllByUtxoKey(List<String> utxoKeyValues) {
    final values = utxoKeyValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'utxoKey', values);
  }

  int deleteAllByUtxoKeySync(List<String> utxoKeyValues) {
    final values = utxoKeyValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'utxoKey', values);
  }

  Future<Id> putByUtxoKey(BitcoinUtxoEntity object) {
    return putByIndex(r'utxoKey', object);
  }

  Id putByUtxoKeySync(BitcoinUtxoEntity object, {bool saveLinks = true}) {
    return putByIndexSync(r'utxoKey', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByUtxoKey(List<BitcoinUtxoEntity> objects) {
    return putAllByIndex(r'utxoKey', objects);
  }

  List<Id> putAllByUtxoKeySync(List<BitcoinUtxoEntity> objects,
      {bool saveLinks = true}) {
    return putAllByIndexSync(r'utxoKey', objects, saveLinks: saveLinks);
  }
}

extension BitcoinUtxoEntityQueryWhereSort
    on QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QWhere> {
  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension BitcoinUtxoEntityQueryWhere
    on QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QWhereClause> {
  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhereClause>
      idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhereClause>
      idNotEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhereClause>
      idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhereClause>
      idLessThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhereClause>
      idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: lowerId,
        includeLower: includeLower,
        upper: upperId,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhereClause>
      walletIdEqualTo(String walletId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'walletId',
        value: [walletId],
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhereClause>
      walletIdNotEqualTo(String walletId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [],
              upper: [walletId],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [walletId],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [walletId],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [],
              upper: [walletId],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhereClause>
      txidEqualTo(String txid) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'txid',
        value: [txid],
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhereClause>
      txidNotEqualTo(String txid) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [],
              upper: [txid],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [txid],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [txid],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [],
              upper: [txid],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhereClause>
      utxoKeyEqualTo(String utxoKey) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'utxoKey',
        value: [utxoKey],
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhereClause>
      utxoKeyNotEqualTo(String utxoKey) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'utxoKey',
              lower: [],
              upper: [utxoKey],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'utxoKey',
              lower: [utxoKey],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'utxoKey',
              lower: [utxoKey],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'utxoKey',
              lower: [],
              upper: [utxoKey],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhereClause>
      statusEqualTo(String status) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'status',
        value: [status],
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterWhereClause>
      statusNotEqualTo(String status) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'status',
              lower: [],
              upper: [status],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'status',
              lower: [status],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'status',
              lower: [status],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'status',
              lower: [],
              upper: [status],
              includeUpper: false,
            ));
      }
    });
  }
}

extension BitcoinUtxoEntityQueryFilter
    on QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QFilterCondition> {
  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      addressIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'address',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      addressIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'address',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      addressEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      addressGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      addressLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      addressBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'address',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      addressStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      addressEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      addressContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      addressMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'address',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      addressIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'address',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      addressIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'address',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      blockHeightIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'blockHeight',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      blockHeightIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'blockHeight',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      blockHeightEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'blockHeight',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      blockHeightGreaterThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'blockHeight',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      blockHeightLessThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'blockHeight',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      blockHeightBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'blockHeight',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      categoryEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'category',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      categoryGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'category',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      categoryLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'category',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      categoryBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'category',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      categoryStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'category',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      categoryEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'category',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      categoryContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'category',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      categoryMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'category',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      categoryIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'category',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      categoryIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'category',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      confirmationsEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'confirmations',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      confirmationsGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'confirmations',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      confirmationsLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'confirmations',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      confirmationsBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'confirmations',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      createdAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      createdAtGreaterThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      createdAtLessThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      createdAtBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'createdAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      idGreaterThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'id',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      isSpendableEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'isSpendable',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      satoshisEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'satoshis',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      satoshisGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'satoshis',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      satoshisLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'satoshis',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      satoshisBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'satoshis',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      satoshisStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'satoshis',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      satoshisEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'satoshis',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      satoshisContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'satoshis',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      satoshisMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'satoshis',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      satoshisIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'satoshis',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      satoshisIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'satoshis',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptPubKeyEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'scriptPubKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptPubKeyGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'scriptPubKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptPubKeyLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'scriptPubKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptPubKeyBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'scriptPubKey',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptPubKeyStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'scriptPubKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptPubKeyEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'scriptPubKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptPubKeyContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'scriptPubKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptPubKeyMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'scriptPubKey',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptPubKeyIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'scriptPubKey',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptPubKeyIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'scriptPubKey',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptTypeEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'scriptType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptTypeGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'scriptType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptTypeLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'scriptType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptTypeBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'scriptType',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptTypeStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'scriptType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptTypeEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'scriptType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptTypeContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'scriptType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptTypeMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'scriptType',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptTypeIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'scriptType',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      scriptTypeIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'scriptType',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentAtIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'spentAt',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentAtIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'spentAt',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentAtEqualTo(DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'spentAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentAtGreaterThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'spentAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentAtLessThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'spentAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentAtBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'spentAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentInTxIdIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'spentInTxId',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentInTxIdIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'spentInTxId',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentInTxIdEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'spentInTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentInTxIdGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'spentInTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentInTxIdLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'spentInTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentInTxIdBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'spentInTxId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentInTxIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'spentInTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentInTxIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'spentInTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentInTxIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'spentInTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentInTxIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'spentInTxId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentInTxIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'spentInTxId',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      spentInTxIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'spentInTxId',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      statusEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      statusGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      statusLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      statusBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'status',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      statusStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      statusEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      statusContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      statusMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'status',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      statusIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'status',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      statusIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'status',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      txidEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      txidGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      txidLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      txidBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'txid',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      txidStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      txidEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      txidContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      txidMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'txid',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      txidIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'txid',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      txidIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'txid',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      utxoKeyEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'utxoKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      utxoKeyGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'utxoKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      utxoKeyLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'utxoKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      utxoKeyBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'utxoKey',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      utxoKeyStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'utxoKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      utxoKeyEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'utxoKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      utxoKeyContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'utxoKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      utxoKeyMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'utxoKey',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      utxoKeyIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'utxoKey',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      utxoKeyIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'utxoKey',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      voutEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'vout',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      voutGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'vout',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      voutLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'vout',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      voutBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'vout',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      walletIdEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      walletIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      walletIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      walletIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'walletId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      walletIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      walletIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      walletIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      walletIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'walletId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      walletIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterFilterCondition>
      walletIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'walletId',
        value: '',
      ));
    });
  }
}

extension BitcoinUtxoEntityQueryObject
    on QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QFilterCondition> {}

extension BitcoinUtxoEntityQueryLinks
    on QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QFilterCondition> {}

extension BitcoinUtxoEntityQuerySortBy
    on QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QSortBy> {
  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByAddress() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByAddressDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByBlockHeight() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHeight', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByBlockHeightDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHeight', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByCategory() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'category', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByCategoryDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'category', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByConfirmations() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmations', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByConfirmationsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmations', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByIsSpendable() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isSpendable', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByIsSpendableDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isSpendable', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortBySatoshis() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'satoshis', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortBySatoshisDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'satoshis', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByScriptPubKey() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scriptPubKey', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByScriptPubKeyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scriptPubKey', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByScriptType() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scriptType', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByScriptTypeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scriptType', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortBySpentAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'spentAt', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortBySpentAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'spentAt', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortBySpentInTxId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'spentInTxId', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortBySpentInTxIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'spentInTxId', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByStatus() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByStatusDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByTxid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByTxidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByUtxoKey() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'utxoKey', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByUtxoKeyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'utxoKey', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByVout() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'vout', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByVoutDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'vout', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      sortByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }
}

extension BitcoinUtxoEntityQuerySortThenBy
    on QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QSortThenBy> {
  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByAddress() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByAddressDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByBlockHeight() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHeight', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByBlockHeightDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHeight', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByCategory() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'category', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByCategoryDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'category', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByConfirmations() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmations', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByConfirmationsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmations', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByIsSpendable() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isSpendable', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByIsSpendableDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isSpendable', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenBySatoshis() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'satoshis', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenBySatoshisDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'satoshis', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByScriptPubKey() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scriptPubKey', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByScriptPubKeyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scriptPubKey', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByScriptType() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scriptType', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByScriptTypeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scriptType', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenBySpentAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'spentAt', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenBySpentAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'spentAt', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenBySpentInTxId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'spentInTxId', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenBySpentInTxIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'spentInTxId', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByStatus() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByStatusDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByTxid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByTxidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByUtxoKey() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'utxoKey', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByUtxoKeyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'utxoKey', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByVout() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'vout', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByVoutDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'vout', Sort.desc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QAfterSortBy>
      thenByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }
}

extension BitcoinUtxoEntityQueryWhereDistinct
    on QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct> {
  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctByAddress({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'address', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctByBlockHeight() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'blockHeight');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctByCategory({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'category', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctByConfirmations() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'confirmations');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'createdAt');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctByIsSpendable() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'isSpendable');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctBySatoshis({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'satoshis', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctByScriptPubKey({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'scriptPubKey', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctByScriptType({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'scriptType', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctBySpentAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'spentAt');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctBySpentInTxId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'spentInTxId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctByStatus({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'status', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct> distinctByTxid(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'txid', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctByUtxoKey({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'utxoKey', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctByVout() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'vout');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QDistinct>
      distinctByWalletId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'walletId', caseSensitive: caseSensitive);
    });
  }
}

extension BitcoinUtxoEntityQueryProperty
    on QueryBuilder<BitcoinUtxoEntity, BitcoinUtxoEntity, QQueryProperty> {
  QueryBuilder<BitcoinUtxoEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, String?, QQueryOperations> addressProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'address');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, int?, QQueryOperations>
      blockHeightProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'blockHeight');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, String, QQueryOperations> categoryProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'category');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, int, QQueryOperations>
      confirmationsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'confirmations');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, DateTime, QQueryOperations>
      createdAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'createdAt');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, bool, QQueryOperations>
      isSpendableProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'isSpendable');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, String, QQueryOperations> satoshisProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'satoshis');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, String, QQueryOperations>
      scriptPubKeyProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'scriptPubKey');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, String, QQueryOperations>
      scriptTypeProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'scriptType');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, DateTime?, QQueryOperations>
      spentAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'spentAt');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, String?, QQueryOperations>
      spentInTxIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'spentInTxId');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, String, QQueryOperations> statusProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'status');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, String, QQueryOperations> txidProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'txid');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, String, QQueryOperations> utxoKeyProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'utxoKey');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, int, QQueryOperations> voutProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'vout');
    });
  }

  QueryBuilder<BitcoinUtxoEntity, String, QQueryOperations> walletIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'walletId');
    });
  }
}

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetBitcoinTransactionEntityCollection on Isar {
  IsarCollection<BitcoinTransactionEntity> get bitcoinTransactionEntitys =>
      this.collection();
}

const BitcoinTransactionEntitySchema = CollectionSchema(
  name: r'BitcoinTransactionEntity',
  id: -8157024933690683657,
  properties: {
    r'blockHash': PropertySchema(
      id: 0,
      name: r'blockHash',
      type: IsarType.string,
    ),
    r'blockHeight': PropertySchema(
      id: 1,
      name: r'blockHeight',
      type: IsarType.long,
    ),
    r'broadcastAt': PropertySchema(
      id: 2,
      name: r'broadcastAt',
      type: IsarType.dateTime,
    ),
    r'confirmations': PropertySchema(
      id: 3,
      name: r'confirmations',
      type: IsarType.long,
    ),
    r'confirmedAt': PropertySchema(
      id: 4,
      name: r'confirmedAt',
      type: IsarType.dateTime,
    ),
    r'counterparty': PropertySchema(
      id: 5,
      name: r'counterparty',
      type: IsarType.string,
    ),
    r'createdAt': PropertySchema(
      id: 6,
      name: r'createdAt',
      type: IsarType.dateTime,
    ),
    r'fee': PropertySchema(
      id: 7,
      name: r'fee',
      type: IsarType.string,
    ),
    r'isIncoming': PropertySchema(
      id: 8,
      name: r'isIncoming',
      type: IsarType.bool,
    ),
    r'isOutgoing': PropertySchema(
      id: 9,
      name: r'isOutgoing',
      type: IsarType.bool,
    ),
    r'netAmount': PropertySchema(
      id: 10,
      name: r'netAmount',
      type: IsarType.string,
    ),
    r'notes': PropertySchema(
      id: 11,
      name: r'notes',
      type: IsarType.string,
    ),
    r'primaryCounterparty': PropertySchema(
      id: 12,
      name: r'primaryCounterparty',
      type: IsarType.string,
    ),
    r'rawHex': PropertySchema(
      id: 13,
      name: r'rawHex',
      type: IsarType.string,
    ),
    r'receivingAddressesJson': PropertySchema(
      id: 14,
      name: r'receivingAddressesJson',
      type: IsarType.string,
    ),
    r'sendingAddressesJson': PropertySchema(
      id: 15,
      name: r'sendingAddressesJson',
      type: IsarType.string,
    ),
    r'status': PropertySchema(
      id: 16,
      name: r'status',
      type: IsarType.string,
    ),
    r'totalInput': PropertySchema(
      id: 17,
      name: r'totalInput',
      type: IsarType.string,
    ),
    r'totalOutput': PropertySchema(
      id: 18,
      name: r'totalOutput',
      type: IsarType.string,
    ),
    r'txid': PropertySchema(
      id: 19,
      name: r'txid',
      type: IsarType.string,
    ),
    r'walletId': PropertySchema(
      id: 20,
      name: r'walletId',
      type: IsarType.string,
    )
  },
  estimateSize: _bitcoinTransactionEntityEstimateSize,
  serialize: _bitcoinTransactionEntitySerialize,
  deserialize: _bitcoinTransactionEntityDeserialize,
  deserializeProp: _bitcoinTransactionEntityDeserializeProp,
  idName: r'id',
  indexes: {
    r'walletId': IndexSchema(
      id: -1783113319798776304,
      name: r'walletId',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'walletId',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'txid': IndexSchema(
      id: 7339874292043634331,
      name: r'txid',
      unique: true,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'txid',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'status': IndexSchema(
      id: -107785170620420283,
      name: r'status',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'status',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'createdAt': IndexSchema(
      id: -3433535483987302584,
      name: r'createdAt',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'createdAt',
          type: IndexType.value,
          caseSensitive: false,
        )
      ],
    ),
    r'primaryCounterparty': IndexSchema(
      id: 4290160039439669883,
      name: r'primaryCounterparty',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'primaryCounterparty',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    )
  },
  links: {},
  embeddedSchemas: {},
  getId: _bitcoinTransactionEntityGetId,
  getLinks: _bitcoinTransactionEntityGetLinks,
  attach: _bitcoinTransactionEntityAttach,
  version: '3.1.0+1',
);

int _bitcoinTransactionEntityEstimateSize(
  BitcoinTransactionEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  {
    final value = object.blockHash;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.counterparty;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.fee.length * 3;
  bytesCount += 3 + object.netAmount.length * 3;
  {
    final value = object.notes;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.primaryCounterparty;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.rawHex.length * 3;
  bytesCount += 3 + object.receivingAddressesJson.length * 3;
  bytesCount += 3 + object.sendingAddressesJson.length * 3;
  bytesCount += 3 + object.status.length * 3;
  bytesCount += 3 + object.totalInput.length * 3;
  bytesCount += 3 + object.totalOutput.length * 3;
  bytesCount += 3 + object.txid.length * 3;
  bytesCount += 3 + object.walletId.length * 3;
  return bytesCount;
}

void _bitcoinTransactionEntitySerialize(
  BitcoinTransactionEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.blockHash);
  writer.writeLong(offsets[1], object.blockHeight);
  writer.writeDateTime(offsets[2], object.broadcastAt);
  writer.writeLong(offsets[3], object.confirmations);
  writer.writeDateTime(offsets[4], object.confirmedAt);
  writer.writeString(offsets[5], object.counterparty);
  writer.writeDateTime(offsets[6], object.createdAt);
  writer.writeString(offsets[7], object.fee);
  writer.writeBool(offsets[8], object.isIncoming);
  writer.writeBool(offsets[9], object.isOutgoing);
  writer.writeString(offsets[10], object.netAmount);
  writer.writeString(offsets[11], object.notes);
  writer.writeString(offsets[12], object.primaryCounterparty);
  writer.writeString(offsets[13], object.rawHex);
  writer.writeString(offsets[14], object.receivingAddressesJson);
  writer.writeString(offsets[15], object.sendingAddressesJson);
  writer.writeString(offsets[16], object.status);
  writer.writeString(offsets[17], object.totalInput);
  writer.writeString(offsets[18], object.totalOutput);
  writer.writeString(offsets[19], object.txid);
  writer.writeString(offsets[20], object.walletId);
}

BitcoinTransactionEntity _bitcoinTransactionEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = BitcoinTransactionEntity();
  object.blockHash = reader.readStringOrNull(offsets[0]);
  object.blockHeight = reader.readLongOrNull(offsets[1]);
  object.broadcastAt = reader.readDateTimeOrNull(offsets[2]);
  object.confirmations = reader.readLong(offsets[3]);
  object.confirmedAt = reader.readDateTimeOrNull(offsets[4]);
  object.counterparty = reader.readStringOrNull(offsets[5]);
  object.createdAt = reader.readDateTime(offsets[6]);
  object.fee = reader.readString(offsets[7]);
  object.id = id;
  object.isIncoming = reader.readBool(offsets[8]);
  object.isOutgoing = reader.readBool(offsets[9]);
  object.netAmount = reader.readString(offsets[10]);
  object.notes = reader.readStringOrNull(offsets[11]);
  object.primaryCounterparty = reader.readStringOrNull(offsets[12]);
  object.rawHex = reader.readString(offsets[13]);
  object.receivingAddressesJson = reader.readString(offsets[14]);
  object.sendingAddressesJson = reader.readString(offsets[15]);
  object.status = reader.readString(offsets[16]);
  object.totalInput = reader.readString(offsets[17]);
  object.totalOutput = reader.readString(offsets[18]);
  object.txid = reader.readString(offsets[19]);
  object.walletId = reader.readString(offsets[20]);
  return object;
}

P _bitcoinTransactionEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readStringOrNull(offset)) as P;
    case 1:
      return (reader.readLongOrNull(offset)) as P;
    case 2:
      return (reader.readDateTimeOrNull(offset)) as P;
    case 3:
      return (reader.readLong(offset)) as P;
    case 4:
      return (reader.readDateTimeOrNull(offset)) as P;
    case 5:
      return (reader.readStringOrNull(offset)) as P;
    case 6:
      return (reader.readDateTime(offset)) as P;
    case 7:
      return (reader.readString(offset)) as P;
    case 8:
      return (reader.readBool(offset)) as P;
    case 9:
      return (reader.readBool(offset)) as P;
    case 10:
      return (reader.readString(offset)) as P;
    case 11:
      return (reader.readStringOrNull(offset)) as P;
    case 12:
      return (reader.readStringOrNull(offset)) as P;
    case 13:
      return (reader.readString(offset)) as P;
    case 14:
      return (reader.readString(offset)) as P;
    case 15:
      return (reader.readString(offset)) as P;
    case 16:
      return (reader.readString(offset)) as P;
    case 17:
      return (reader.readString(offset)) as P;
    case 18:
      return (reader.readString(offset)) as P;
    case 19:
      return (reader.readString(offset)) as P;
    case 20:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _bitcoinTransactionEntityGetId(BitcoinTransactionEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _bitcoinTransactionEntityGetLinks(
    BitcoinTransactionEntity object) {
  return [];
}

void _bitcoinTransactionEntityAttach(
    IsarCollection<dynamic> col, Id id, BitcoinTransactionEntity object) {
  object.id = id;
}

extension BitcoinTransactionEntityByIndex
    on IsarCollection<BitcoinTransactionEntity> {
  Future<BitcoinTransactionEntity?> getByTxid(String txid) {
    return getByIndex(r'txid', [txid]);
  }

  BitcoinTransactionEntity? getByTxidSync(String txid) {
    return getByIndexSync(r'txid', [txid]);
  }

  Future<bool> deleteByTxid(String txid) {
    return deleteByIndex(r'txid', [txid]);
  }

  bool deleteByTxidSync(String txid) {
    return deleteByIndexSync(r'txid', [txid]);
  }

  Future<List<BitcoinTransactionEntity?>> getAllByTxid(
      List<String> txidValues) {
    final values = txidValues.map((e) => [e]).toList();
    return getAllByIndex(r'txid', values);
  }

  List<BitcoinTransactionEntity?> getAllByTxidSync(List<String> txidValues) {
    final values = txidValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'txid', values);
  }

  Future<int> deleteAllByTxid(List<String> txidValues) {
    final values = txidValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'txid', values);
  }

  int deleteAllByTxidSync(List<String> txidValues) {
    final values = txidValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'txid', values);
  }

  Future<Id> putByTxid(BitcoinTransactionEntity object) {
    return putByIndex(r'txid', object);
  }

  Id putByTxidSync(BitcoinTransactionEntity object, {bool saveLinks = true}) {
    return putByIndexSync(r'txid', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByTxid(List<BitcoinTransactionEntity> objects) {
    return putAllByIndex(r'txid', objects);
  }

  List<Id> putAllByTxidSync(List<BitcoinTransactionEntity> objects,
      {bool saveLinks = true}) {
    return putAllByIndexSync(r'txid', objects, saveLinks: saveLinks);
  }
}

extension BitcoinTransactionEntityQueryWhereSort on QueryBuilder<
    BitcoinTransactionEntity, BitcoinTransactionEntity, QWhere> {
  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterWhere>
      anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterWhere>
      anyCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'createdAt'),
      );
    });
  }
}

extension BitcoinTransactionEntityQueryWhere on QueryBuilder<
    BitcoinTransactionEntity, BitcoinTransactionEntity, QWhereClause> {
  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> idNotEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> idLessThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: lowerId,
        includeLower: includeLower,
        upper: upperId,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> walletIdEqualTo(String walletId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'walletId',
        value: [walletId],
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> walletIdNotEqualTo(String walletId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [],
              upper: [walletId],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [walletId],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [walletId],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [],
              upper: [walletId],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> txidEqualTo(String txid) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'txid',
        value: [txid],
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> txidNotEqualTo(String txid) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [],
              upper: [txid],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [txid],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [txid],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [],
              upper: [txid],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> statusEqualTo(String status) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'status',
        value: [status],
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> statusNotEqualTo(String status) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'status',
              lower: [],
              upper: [status],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'status',
              lower: [status],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'status',
              lower: [status],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'status',
              lower: [],
              upper: [status],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> createdAtEqualTo(DateTime createdAt) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'createdAt',
        value: [createdAt],
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> createdAtNotEqualTo(DateTime createdAt) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'createdAt',
              lower: [],
              upper: [createdAt],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'createdAt',
              lower: [createdAt],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'createdAt',
              lower: [createdAt],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'createdAt',
              lower: [],
              upper: [createdAt],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> createdAtGreaterThan(
    DateTime createdAt, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'createdAt',
        lower: [createdAt],
        includeLower: include,
        upper: [],
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> createdAtLessThan(
    DateTime createdAt, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'createdAt',
        lower: [],
        upper: [createdAt],
        includeUpper: include,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> createdAtBetween(
    DateTime lowerCreatedAt,
    DateTime upperCreatedAt, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'createdAt',
        lower: [lowerCreatedAt],
        includeLower: includeLower,
        upper: [upperCreatedAt],
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> primaryCounterpartyIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'primaryCounterparty',
        value: [null],
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterWhereClause> primaryCounterpartyIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'primaryCounterparty',
        lower: [null],
        includeLower: false,
        upper: [],
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterWhereClause>
      primaryCounterpartyEqualTo(String? primaryCounterparty) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'primaryCounterparty',
        value: [primaryCounterparty],
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterWhereClause>
      primaryCounterpartyNotEqualTo(String? primaryCounterparty) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'primaryCounterparty',
              lower: [],
              upper: [primaryCounterparty],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'primaryCounterparty',
              lower: [primaryCounterparty],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'primaryCounterparty',
              lower: [primaryCounterparty],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'primaryCounterparty',
              lower: [],
              upper: [primaryCounterparty],
              includeUpper: false,
            ));
      }
    });
  }
}

extension BitcoinTransactionEntityQueryFilter on QueryBuilder<
    BitcoinTransactionEntity, BitcoinTransactionEntity, QFilterCondition> {
  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHashIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'blockHash',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHashIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'blockHash',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHashEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'blockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHashGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'blockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHashLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'blockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHashBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'blockHash',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHashStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'blockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHashEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'blockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      blockHashContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'blockHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      blockHashMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'blockHash',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHashIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'blockHash',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHashIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'blockHash',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHeightIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'blockHeight',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHeightIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'blockHeight',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHeightEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'blockHeight',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHeightGreaterThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'blockHeight',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHeightLessThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'blockHeight',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> blockHeightBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'blockHeight',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> broadcastAtIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'broadcastAt',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> broadcastAtIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'broadcastAt',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> broadcastAtEqualTo(DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'broadcastAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> broadcastAtGreaterThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'broadcastAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> broadcastAtLessThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'broadcastAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> broadcastAtBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'broadcastAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> confirmationsEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'confirmations',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> confirmationsGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'confirmations',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> confirmationsLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'confirmations',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> confirmationsBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'confirmations',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> confirmedAtIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'confirmedAt',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> confirmedAtIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'confirmedAt',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> confirmedAtEqualTo(DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'confirmedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> confirmedAtGreaterThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'confirmedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> confirmedAtLessThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'confirmedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> confirmedAtBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'confirmedAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> counterpartyIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'counterparty',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> counterpartyIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'counterparty',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> counterpartyEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'counterparty',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> counterpartyGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'counterparty',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> counterpartyLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'counterparty',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> counterpartyBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'counterparty',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> counterpartyStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'counterparty',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> counterpartyEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'counterparty',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      counterpartyContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'counterparty',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      counterpartyMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'counterparty',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> counterpartyIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'counterparty',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> counterpartyIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'counterparty',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> createdAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> createdAtGreaterThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> createdAtLessThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> createdAtBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'createdAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> feeEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'fee',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> feeGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'fee',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> feeLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'fee',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> feeBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'fee',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> feeStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'fee',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> feeEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'fee',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      feeContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'fee',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      feeMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'fee',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> feeIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'fee',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> feeIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'fee',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> idGreaterThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'id',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> isIncomingEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'isIncoming',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> isOutgoingEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'isOutgoing',
        value: value,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> netAmountEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'netAmount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> netAmountGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'netAmount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> netAmountLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'netAmount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> netAmountBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'netAmount',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> netAmountStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'netAmount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> netAmountEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'netAmount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      netAmountContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'netAmount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      netAmountMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'netAmount',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> netAmountIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'netAmount',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> netAmountIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'netAmount',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> notesIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'notes',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> notesIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'notes',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> notesEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'notes',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> notesGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'notes',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> notesLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'notes',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> notesBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'notes',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> notesStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'notes',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> notesEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'notes',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      notesContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'notes',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      notesMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'notes',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> notesIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'notes',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> notesIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'notes',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> primaryCounterpartyIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'primaryCounterparty',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> primaryCounterpartyIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'primaryCounterparty',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> primaryCounterpartyEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'primaryCounterparty',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> primaryCounterpartyGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'primaryCounterparty',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> primaryCounterpartyLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'primaryCounterparty',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> primaryCounterpartyBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'primaryCounterparty',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> primaryCounterpartyStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'primaryCounterparty',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> primaryCounterpartyEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'primaryCounterparty',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      primaryCounterpartyContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'primaryCounterparty',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      primaryCounterpartyMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'primaryCounterparty',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> primaryCounterpartyIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'primaryCounterparty',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> primaryCounterpartyIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'primaryCounterparty',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> rawHexEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'rawHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> rawHexGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'rawHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> rawHexLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'rawHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> rawHexBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'rawHex',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> rawHexStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'rawHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> rawHexEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'rawHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      rawHexContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'rawHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      rawHexMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'rawHex',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> rawHexIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'rawHex',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> rawHexIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'rawHex',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> receivingAddressesJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'receivingAddressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> receivingAddressesJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'receivingAddressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> receivingAddressesJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'receivingAddressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> receivingAddressesJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'receivingAddressesJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> receivingAddressesJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'receivingAddressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> receivingAddressesJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'receivingAddressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      receivingAddressesJsonContains(String value,
          {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'receivingAddressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      receivingAddressesJsonMatches(String pattern,
          {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'receivingAddressesJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> receivingAddressesJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'receivingAddressesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> receivingAddressesJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'receivingAddressesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> sendingAddressesJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'sendingAddressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> sendingAddressesJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'sendingAddressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> sendingAddressesJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'sendingAddressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> sendingAddressesJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'sendingAddressesJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> sendingAddressesJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'sendingAddressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> sendingAddressesJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'sendingAddressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      sendingAddressesJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'sendingAddressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      sendingAddressesJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'sendingAddressesJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> sendingAddressesJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'sendingAddressesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> sendingAddressesJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'sendingAddressesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> statusEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> statusGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> statusLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> statusBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'status',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> statusStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> statusEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      statusContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      statusMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'status',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> statusIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'status',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> statusIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'status',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalInputEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'totalInput',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalInputGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'totalInput',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalInputLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'totalInput',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalInputBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'totalInput',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalInputStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'totalInput',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalInputEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'totalInput',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      totalInputContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'totalInput',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      totalInputMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'totalInput',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalInputIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'totalInput',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalInputIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'totalInput',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalOutputEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'totalOutput',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalOutputGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'totalOutput',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalOutputLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'totalOutput',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalOutputBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'totalOutput',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalOutputStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'totalOutput',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalOutputEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'totalOutput',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      totalOutputContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'totalOutput',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      totalOutputMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'totalOutput',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalOutputIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'totalOutput',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> totalOutputIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'totalOutput',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> txidEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> txidGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> txidLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> txidBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'txid',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> txidStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> txidEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      txidContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      txidMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'txid',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> txidIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'txid',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> txidIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'txid',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> walletIdEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> walletIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> walletIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> walletIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'walletId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> walletIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> walletIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      walletIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
          QAfterFilterCondition>
      walletIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'walletId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> walletIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: '',
      ));
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity,
      QAfterFilterCondition> walletIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'walletId',
        value: '',
      ));
    });
  }
}

extension BitcoinTransactionEntityQueryObject on QueryBuilder<
    BitcoinTransactionEntity, BitcoinTransactionEntity, QFilterCondition> {}

extension BitcoinTransactionEntityQueryLinks on QueryBuilder<
    BitcoinTransactionEntity, BitcoinTransactionEntity, QFilterCondition> {}

extension BitcoinTransactionEntityQuerySortBy on QueryBuilder<
    BitcoinTransactionEntity, BitcoinTransactionEntity, QSortBy> {
  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByBlockHash() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHash', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByBlockHashDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHash', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByBlockHeight() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHeight', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByBlockHeightDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHeight', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByBroadcastAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'broadcastAt', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByBroadcastAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'broadcastAt', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByConfirmations() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmations', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByConfirmationsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmations', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByConfirmedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmedAt', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByConfirmedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmedAt', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByCounterparty() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'counterparty', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByCounterpartyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'counterparty', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByFee() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fee', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByFeeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fee', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByIsIncoming() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isIncoming', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByIsIncomingDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isIncoming', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByIsOutgoing() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isOutgoing', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByIsOutgoingDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isOutgoing', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByNetAmount() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'netAmount', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByNetAmountDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'netAmount', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByNotes() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'notes', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByNotesDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'notes', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByPrimaryCounterparty() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'primaryCounterparty', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByPrimaryCounterpartyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'primaryCounterparty', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByRawHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'rawHex', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByRawHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'rawHex', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByReceivingAddressesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'receivingAddressesJson', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByReceivingAddressesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'receivingAddressesJson', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortBySendingAddressesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sendingAddressesJson', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortBySendingAddressesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sendingAddressesJson', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByStatus() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByStatusDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByTotalInput() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'totalInput', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByTotalInputDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'totalInput', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByTotalOutput() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'totalOutput', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByTotalOutputDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'totalOutput', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByTxid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByTxidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      sortByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }
}

extension BitcoinTransactionEntityQuerySortThenBy on QueryBuilder<
    BitcoinTransactionEntity, BitcoinTransactionEntity, QSortThenBy> {
  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByBlockHash() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHash', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByBlockHashDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHash', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByBlockHeight() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHeight', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByBlockHeightDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockHeight', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByBroadcastAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'broadcastAt', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByBroadcastAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'broadcastAt', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByConfirmations() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmations', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByConfirmationsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmations', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByConfirmedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmedAt', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByConfirmedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmedAt', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByCounterparty() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'counterparty', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByCounterpartyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'counterparty', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByFee() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fee', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByFeeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fee', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByIsIncoming() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isIncoming', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByIsIncomingDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isIncoming', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByIsOutgoing() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isOutgoing', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByIsOutgoingDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isOutgoing', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByNetAmount() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'netAmount', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByNetAmountDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'netAmount', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByNotes() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'notes', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByNotesDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'notes', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByPrimaryCounterparty() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'primaryCounterparty', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByPrimaryCounterpartyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'primaryCounterparty', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByRawHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'rawHex', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByRawHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'rawHex', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByReceivingAddressesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'receivingAddressesJson', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByReceivingAddressesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'receivingAddressesJson', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenBySendingAddressesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sendingAddressesJson', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenBySendingAddressesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sendingAddressesJson', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByStatus() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByStatusDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByTotalInput() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'totalInput', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByTotalInputDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'totalInput', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByTotalOutput() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'totalOutput', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByTotalOutputDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'totalOutput', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByTxid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByTxidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.desc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QAfterSortBy>
      thenByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }
}

extension BitcoinTransactionEntityQueryWhereDistinct on QueryBuilder<
    BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct> {
  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByBlockHash({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'blockHash', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByBlockHeight() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'blockHeight');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByBroadcastAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'broadcastAt');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByConfirmations() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'confirmations');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByConfirmedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'confirmedAt');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByCounterparty({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'counterparty', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'createdAt');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByFee({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'fee', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByIsIncoming() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'isIncoming');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByIsOutgoing() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'isOutgoing');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByNetAmount({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'netAmount', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByNotes({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'notes', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByPrimaryCounterparty({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'primaryCounterparty',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByRawHex({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'rawHex', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByReceivingAddressesJson({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'receivingAddressesJson',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctBySendingAddressesJson({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'sendingAddressesJson',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByStatus({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'status', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByTotalInput({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'totalInput', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByTotalOutput({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'totalOutput', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByTxid({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'txid', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BitcoinTransactionEntity, BitcoinTransactionEntity, QDistinct>
      distinctByWalletId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'walletId', caseSensitive: caseSensitive);
    });
  }
}

extension BitcoinTransactionEntityQueryProperty on QueryBuilder<
    BitcoinTransactionEntity, BitcoinTransactionEntity, QQueryProperty> {
  QueryBuilder<BitcoinTransactionEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, String?, QQueryOperations>
      blockHashProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'blockHash');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, int?, QQueryOperations>
      blockHeightProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'blockHeight');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, DateTime?, QQueryOperations>
      broadcastAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'broadcastAt');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, int, QQueryOperations>
      confirmationsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'confirmations');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, DateTime?, QQueryOperations>
      confirmedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'confirmedAt');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, String?, QQueryOperations>
      counterpartyProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'counterparty');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, DateTime, QQueryOperations>
      createdAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'createdAt');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, String, QQueryOperations>
      feeProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'fee');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, bool, QQueryOperations>
      isIncomingProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'isIncoming');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, bool, QQueryOperations>
      isOutgoingProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'isOutgoing');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, String, QQueryOperations>
      netAmountProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'netAmount');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, String?, QQueryOperations>
      notesProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'notes');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, String?, QQueryOperations>
      primaryCounterpartyProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'primaryCounterparty');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, String, QQueryOperations>
      rawHexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'rawHex');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, String, QQueryOperations>
      receivingAddressesJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'receivingAddressesJson');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, String, QQueryOperations>
      sendingAddressesJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'sendingAddressesJson');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, String, QQueryOperations>
      statusProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'status');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, String, QQueryOperations>
      totalInputProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'totalInput');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, String, QQueryOperations>
      totalOutputProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'totalOutput');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, String, QQueryOperations>
      txidProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'txid');
    });
  }

  QueryBuilder<BitcoinTransactionEntity, String, QQueryOperations>
      walletIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'walletId');
    });
  }
}

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetWalletMetadataEntityCollection on Isar {
  IsarCollection<WalletMetadataEntity> get walletMetadataEntitys =>
      this.collection();
}

const WalletMetadataEntitySchema = CollectionSchema(
  name: r'WalletMetadataEntity',
  id: 6839345711368541396,
  properties: {
    r'addressesJson': PropertySchema(
      id: 0,
      name: r'addressesJson',
      type: IsarType.string,
    ),
    r'aggregateVersion': PropertySchema(
      id: 1,
      name: r'aggregateVersion',
      type: IsarType.long,
    ),
    r'confirmedBalance': PropertySchema(
      id: 2,
      name: r'confirmedBalance',
      type: IsarType.string,
    ),
    r'createdAt': PropertySchema(
      id: 3,
      name: r'createdAt',
      type: IsarType.dateTime,
    ),
    r'derivationIndex': PropertySchema(
      id: 4,
      name: r'derivationIndex',
      type: IsarType.long,
    ),
    r'isCreated': PropertySchema(
      id: 5,
      name: r'isCreated',
      type: IsarType.bool,
    ),
    r'lastAccessedAt': PropertySchema(
      id: 6,
      name: r'lastAccessedAt',
      type: IsarType.dateTime,
    ),
    r'metadataJson': PropertySchema(
      id: 7,
      name: r'metadataJson',
      type: IsarType.string,
    ),
    r'name': PropertySchema(
      id: 8,
      name: r'name',
      type: IsarType.string,
    ),
    r'network': PropertySchema(
      id: 9,
      name: r'network',
      type: IsarType.string,
    ),
    r'publicKeysJson': PropertySchema(
      id: 10,
      name: r'publicKeysJson',
      type: IsarType.string,
    ),
    r'rootAddress': PropertySchema(
      id: 11,
      name: r'rootAddress',
      type: IsarType.string,
    ),
    r'unconfirmedBalance': PropertySchema(
      id: 12,
      name: r'unconfirmedBalance',
      type: IsarType.string,
    ),
    r'walletId': PropertySchema(
      id: 13,
      name: r'walletId',
      type: IsarType.string,
    ),
    r'walletType': PropertySchema(
      id: 14,
      name: r'walletType',
      type: IsarType.string,
    )
  },
  estimateSize: _walletMetadataEntityEstimateSize,
  serialize: _walletMetadataEntitySerialize,
  deserialize: _walletMetadataEntityDeserialize,
  deserializeProp: _walletMetadataEntityDeserializeProp,
  idName: r'id',
  indexes: {
    r'walletId': IndexSchema(
      id: -1783113319798776304,
      name: r'walletId',
      unique: true,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'walletId',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    )
  },
  links: {},
  embeddedSchemas: {},
  getId: _walletMetadataEntityGetId,
  getLinks: _walletMetadataEntityGetLinks,
  attach: _walletMetadataEntityAttach,
  version: '3.1.0+1',
);

int _walletMetadataEntityEstimateSize(
  WalletMetadataEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.addressesJson.length * 3;
  bytesCount += 3 + object.confirmedBalance.length * 3;
  bytesCount += 3 + object.metadataJson.length * 3;
  bytesCount += 3 + object.name.length * 3;
  bytesCount += 3 + object.network.length * 3;
  bytesCount += 3 + object.publicKeysJson.length * 3;
  {
    final value = object.rootAddress;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.unconfirmedBalance.length * 3;
  bytesCount += 3 + object.walletId.length * 3;
  bytesCount += 3 + object.walletType.length * 3;
  return bytesCount;
}

void _walletMetadataEntitySerialize(
  WalletMetadataEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.addressesJson);
  writer.writeLong(offsets[1], object.aggregateVersion);
  writer.writeString(offsets[2], object.confirmedBalance);
  writer.writeDateTime(offsets[3], object.createdAt);
  writer.writeLong(offsets[4], object.derivationIndex);
  writer.writeBool(offsets[5], object.isCreated);
  writer.writeDateTime(offsets[6], object.lastAccessedAt);
  writer.writeString(offsets[7], object.metadataJson);
  writer.writeString(offsets[8], object.name);
  writer.writeString(offsets[9], object.network);
  writer.writeString(offsets[10], object.publicKeysJson);
  writer.writeString(offsets[11], object.rootAddress);
  writer.writeString(offsets[12], object.unconfirmedBalance);
  writer.writeString(offsets[13], object.walletId);
  writer.writeString(offsets[14], object.walletType);
}

WalletMetadataEntity _walletMetadataEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = WalletMetadataEntity();
  object.addressesJson = reader.readString(offsets[0]);
  object.aggregateVersion = reader.readLong(offsets[1]);
  object.confirmedBalance = reader.readString(offsets[2]);
  object.createdAt = reader.readDateTime(offsets[3]);
  object.derivationIndex = reader.readLong(offsets[4]);
  object.id = id;
  object.isCreated = reader.readBool(offsets[5]);
  object.lastAccessedAt = reader.readDateTime(offsets[6]);
  object.metadataJson = reader.readString(offsets[7]);
  object.name = reader.readString(offsets[8]);
  object.network = reader.readString(offsets[9]);
  object.publicKeysJson = reader.readString(offsets[10]);
  object.rootAddress = reader.readStringOrNull(offsets[11]);
  object.unconfirmedBalance = reader.readString(offsets[12]);
  object.walletId = reader.readString(offsets[13]);
  object.walletType = reader.readString(offsets[14]);
  return object;
}

P _walletMetadataEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readString(offset)) as P;
    case 1:
      return (reader.readLong(offset)) as P;
    case 2:
      return (reader.readString(offset)) as P;
    case 3:
      return (reader.readDateTime(offset)) as P;
    case 4:
      return (reader.readLong(offset)) as P;
    case 5:
      return (reader.readBool(offset)) as P;
    case 6:
      return (reader.readDateTime(offset)) as P;
    case 7:
      return (reader.readString(offset)) as P;
    case 8:
      return (reader.readString(offset)) as P;
    case 9:
      return (reader.readString(offset)) as P;
    case 10:
      return (reader.readString(offset)) as P;
    case 11:
      return (reader.readStringOrNull(offset)) as P;
    case 12:
      return (reader.readString(offset)) as P;
    case 13:
      return (reader.readString(offset)) as P;
    case 14:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _walletMetadataEntityGetId(WalletMetadataEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _walletMetadataEntityGetLinks(
    WalletMetadataEntity object) {
  return [];
}

void _walletMetadataEntityAttach(
    IsarCollection<dynamic> col, Id id, WalletMetadataEntity object) {
  object.id = id;
}

extension WalletMetadataEntityByIndex on IsarCollection<WalletMetadataEntity> {
  Future<WalletMetadataEntity?> getByWalletId(String walletId) {
    return getByIndex(r'walletId', [walletId]);
  }

  WalletMetadataEntity? getByWalletIdSync(String walletId) {
    return getByIndexSync(r'walletId', [walletId]);
  }

  Future<bool> deleteByWalletId(String walletId) {
    return deleteByIndex(r'walletId', [walletId]);
  }

  bool deleteByWalletIdSync(String walletId) {
    return deleteByIndexSync(r'walletId', [walletId]);
  }

  Future<List<WalletMetadataEntity?>> getAllByWalletId(
      List<String> walletIdValues) {
    final values = walletIdValues.map((e) => [e]).toList();
    return getAllByIndex(r'walletId', values);
  }

  List<WalletMetadataEntity?> getAllByWalletIdSync(
      List<String> walletIdValues) {
    final values = walletIdValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'walletId', values);
  }

  Future<int> deleteAllByWalletId(List<String> walletIdValues) {
    final values = walletIdValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'walletId', values);
  }

  int deleteAllByWalletIdSync(List<String> walletIdValues) {
    final values = walletIdValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'walletId', values);
  }

  Future<Id> putByWalletId(WalletMetadataEntity object) {
    return putByIndex(r'walletId', object);
  }

  Id putByWalletIdSync(WalletMetadataEntity object, {bool saveLinks = true}) {
    return putByIndexSync(r'walletId', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByWalletId(List<WalletMetadataEntity> objects) {
    return putAllByIndex(r'walletId', objects);
  }

  List<Id> putAllByWalletIdSync(List<WalletMetadataEntity> objects,
      {bool saveLinks = true}) {
    return putAllByIndexSync(r'walletId', objects, saveLinks: saveLinks);
  }
}

extension WalletMetadataEntityQueryWhereSort
    on QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QWhere> {
  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterWhere>
      anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension WalletMetadataEntityQueryWhere
    on QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QWhereClause> {
  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterWhereClause>
      idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterWhereClause>
      idNotEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterWhereClause>
      idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterWhereClause>
      idLessThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterWhereClause>
      idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: lowerId,
        includeLower: includeLower,
        upper: upperId,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterWhereClause>
      walletIdEqualTo(String walletId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'walletId',
        value: [walletId],
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterWhereClause>
      walletIdNotEqualTo(String walletId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [],
              upper: [walletId],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [walletId],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [walletId],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [],
              upper: [walletId],
              includeUpper: false,
            ));
      }
    });
  }
}

extension WalletMetadataEntityQueryFilter on QueryBuilder<WalletMetadataEntity,
    WalletMetadataEntity, QFilterCondition> {
  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> addressesJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'addressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> addressesJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'addressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> addressesJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'addressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> addressesJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'addressesJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> addressesJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'addressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> addressesJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'addressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      addressesJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'addressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      addressesJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'addressesJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> addressesJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'addressesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> addressesJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'addressesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> aggregateVersionEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'aggregateVersion',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> aggregateVersionGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'aggregateVersion',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> aggregateVersionLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'aggregateVersion',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> aggregateVersionBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'aggregateVersion',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> confirmedBalanceEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'confirmedBalance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> confirmedBalanceGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'confirmedBalance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> confirmedBalanceLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'confirmedBalance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> confirmedBalanceBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'confirmedBalance',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> confirmedBalanceStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'confirmedBalance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> confirmedBalanceEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'confirmedBalance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      confirmedBalanceContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'confirmedBalance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      confirmedBalanceMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'confirmedBalance',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> confirmedBalanceIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'confirmedBalance',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> confirmedBalanceIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'confirmedBalance',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> createdAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> createdAtGreaterThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> createdAtLessThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> createdAtBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'createdAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> derivationIndexEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'derivationIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> derivationIndexGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'derivationIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> derivationIndexLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'derivationIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> derivationIndexBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'derivationIndex',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> idGreaterThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'id',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> isCreatedEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'isCreated',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> lastAccessedAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'lastAccessedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> lastAccessedAtGreaterThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'lastAccessedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> lastAccessedAtLessThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'lastAccessedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> lastAccessedAtBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'lastAccessedAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> metadataJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'metadataJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> metadataJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'metadataJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> metadataJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'metadataJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> metadataJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'metadataJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> metadataJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'metadataJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> metadataJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'metadataJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      metadataJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'metadataJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      metadataJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'metadataJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> metadataJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'metadataJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> metadataJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'metadataJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> nameEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'name',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> nameGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'name',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> nameLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'name',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> nameBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'name',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> nameStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'name',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> nameEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'name',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      nameContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'name',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      nameMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'name',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> nameIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'name',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> nameIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'name',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> networkEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'network',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> networkGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'network',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> networkLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'network',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> networkBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'network',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> networkStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'network',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> networkEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'network',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      networkContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'network',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      networkMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'network',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> networkIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'network',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> networkIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'network',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> publicKeysJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'publicKeysJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> publicKeysJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'publicKeysJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> publicKeysJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'publicKeysJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> publicKeysJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'publicKeysJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> publicKeysJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'publicKeysJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> publicKeysJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'publicKeysJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      publicKeysJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'publicKeysJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      publicKeysJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'publicKeysJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> publicKeysJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'publicKeysJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> publicKeysJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'publicKeysJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> rootAddressIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'rootAddress',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> rootAddressIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'rootAddress',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> rootAddressEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'rootAddress',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> rootAddressGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'rootAddress',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> rootAddressLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'rootAddress',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> rootAddressBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'rootAddress',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> rootAddressStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'rootAddress',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> rootAddressEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'rootAddress',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      rootAddressContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'rootAddress',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      rootAddressMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'rootAddress',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> rootAddressIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'rootAddress',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> rootAddressIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'rootAddress',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> unconfirmedBalanceEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'unconfirmedBalance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> unconfirmedBalanceGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'unconfirmedBalance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> unconfirmedBalanceLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'unconfirmedBalance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> unconfirmedBalanceBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'unconfirmedBalance',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> unconfirmedBalanceStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'unconfirmedBalance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> unconfirmedBalanceEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'unconfirmedBalance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      unconfirmedBalanceContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'unconfirmedBalance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      unconfirmedBalanceMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'unconfirmedBalance',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> unconfirmedBalanceIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'unconfirmedBalance',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> unconfirmedBalanceIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'unconfirmedBalance',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletIdEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'walletId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      walletIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      walletIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'walletId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'walletId',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletTypeEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletTypeGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'walletType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletTypeLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'walletType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletTypeBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'walletType',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletTypeStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'walletType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletTypeEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'walletType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      walletTypeContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'walletType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
          QAfterFilterCondition>
      walletTypeMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'walletType',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletTypeIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletType',
        value: '',
      ));
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity,
      QAfterFilterCondition> walletTypeIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'walletType',
        value: '',
      ));
    });
  }
}

extension WalletMetadataEntityQueryObject on QueryBuilder<WalletMetadataEntity,
    WalletMetadataEntity, QFilterCondition> {}

extension WalletMetadataEntityQueryLinks on QueryBuilder<WalletMetadataEntity,
    WalletMetadataEntity, QFilterCondition> {}

extension WalletMetadataEntityQuerySortBy
    on QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QSortBy> {
  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByAddressesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'addressesJson', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByAddressesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'addressesJson', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByAggregateVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'aggregateVersion', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByAggregateVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'aggregateVersion', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByConfirmedBalance() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmedBalance', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByConfirmedBalanceDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmedBalance', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByDerivationIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'derivationIndex', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByDerivationIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'derivationIndex', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByIsCreated() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isCreated', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByIsCreatedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isCreated', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByLastAccessedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastAccessedAt', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByLastAccessedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastAccessedAt', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByMetadataJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'metadataJson', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByMetadataJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'metadataJson', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'name', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByNameDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'name', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByNetwork() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'network', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByNetworkDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'network', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByPublicKeysJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'publicKeysJson', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByPublicKeysJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'publicKeysJson', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByRootAddress() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'rootAddress', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByRootAddressDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'rootAddress', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByUnconfirmedBalance() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'unconfirmedBalance', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByUnconfirmedBalanceDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'unconfirmedBalance', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByWalletType() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletType', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      sortByWalletTypeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletType', Sort.desc);
    });
  }
}

extension WalletMetadataEntityQuerySortThenBy
    on QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QSortThenBy> {
  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByAddressesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'addressesJson', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByAddressesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'addressesJson', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByAggregateVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'aggregateVersion', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByAggregateVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'aggregateVersion', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByConfirmedBalance() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmedBalance', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByConfirmedBalanceDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'confirmedBalance', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByDerivationIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'derivationIndex', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByDerivationIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'derivationIndex', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByIsCreated() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isCreated', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByIsCreatedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isCreated', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByLastAccessedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastAccessedAt', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByLastAccessedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastAccessedAt', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByMetadataJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'metadataJson', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByMetadataJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'metadataJson', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'name', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByNameDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'name', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByNetwork() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'network', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByNetworkDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'network', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByPublicKeysJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'publicKeysJson', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByPublicKeysJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'publicKeysJson', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByRootAddress() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'rootAddress', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByRootAddressDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'rootAddress', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByUnconfirmedBalance() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'unconfirmedBalance', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByUnconfirmedBalanceDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'unconfirmedBalance', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByWalletType() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletType', Sort.asc);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QAfterSortBy>
      thenByWalletTypeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletType', Sort.desc);
    });
  }
}

extension WalletMetadataEntityQueryWhereDistinct
    on QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct> {
  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByAddressesJson({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'addressesJson',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByAggregateVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'aggregateVersion');
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByConfirmedBalance({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'confirmedBalance',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'createdAt');
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByDerivationIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'derivationIndex');
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByIsCreated() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'isCreated');
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByLastAccessedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'lastAccessedAt');
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByMetadataJson({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'metadataJson', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByName({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'name', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByNetwork({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'network', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByPublicKeysJson({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'publicKeysJson',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByRootAddress({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'rootAddress', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByUnconfirmedBalance({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'unconfirmedBalance',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByWalletId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'walletId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WalletMetadataEntity, WalletMetadataEntity, QDistinct>
      distinctByWalletType({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'walletType', caseSensitive: caseSensitive);
    });
  }
}

extension WalletMetadataEntityQueryProperty on QueryBuilder<
    WalletMetadataEntity, WalletMetadataEntity, QQueryProperty> {
  QueryBuilder<WalletMetadataEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<WalletMetadataEntity, String, QQueryOperations>
      addressesJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'addressesJson');
    });
  }

  QueryBuilder<WalletMetadataEntity, int, QQueryOperations>
      aggregateVersionProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'aggregateVersion');
    });
  }

  QueryBuilder<WalletMetadataEntity, String, QQueryOperations>
      confirmedBalanceProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'confirmedBalance');
    });
  }

  QueryBuilder<WalletMetadataEntity, DateTime, QQueryOperations>
      createdAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'createdAt');
    });
  }

  QueryBuilder<WalletMetadataEntity, int, QQueryOperations>
      derivationIndexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'derivationIndex');
    });
  }

  QueryBuilder<WalletMetadataEntity, bool, QQueryOperations>
      isCreatedProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'isCreated');
    });
  }

  QueryBuilder<WalletMetadataEntity, DateTime, QQueryOperations>
      lastAccessedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'lastAccessedAt');
    });
  }

  QueryBuilder<WalletMetadataEntity, String, QQueryOperations>
      metadataJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'metadataJson');
    });
  }

  QueryBuilder<WalletMetadataEntity, String, QQueryOperations> nameProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'name');
    });
  }

  QueryBuilder<WalletMetadataEntity, String, QQueryOperations>
      networkProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'network');
    });
  }

  QueryBuilder<WalletMetadataEntity, String, QQueryOperations>
      publicKeysJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'publicKeysJson');
    });
  }

  QueryBuilder<WalletMetadataEntity, String?, QQueryOperations>
      rootAddressProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'rootAddress');
    });
  }

  QueryBuilder<WalletMetadataEntity, String, QQueryOperations>
      unconfirmedBalanceProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'unconfirmedBalance');
    });
  }

  QueryBuilder<WalletMetadataEntity, String, QQueryOperations>
      walletIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'walletId');
    });
  }

  QueryBuilder<WalletMetadataEntity, String, QQueryOperations>
      walletTypeProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'walletType');
    });
  }
}

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetAddressEntityCollection on Isar {
  IsarCollection<AddressEntity> get addressEntitys => this.collection();
}

const AddressEntitySchema = CollectionSchema(
  name: r'AddressEntity',
  id: 5884920456001426106,
  properties: {
    r'address': PropertySchema(
      id: 0,
      name: r'address',
      type: IsarType.string,
    ),
    r'balance': PropertySchema(
      id: 1,
      name: r'balance',
      type: IsarType.string,
    ),
    r'createdAt': PropertySchema(
      id: 2,
      name: r'createdAt',
      type: IsarType.dateTime,
    ),
    r'derivationIndex': PropertySchema(
      id: 3,
      name: r'derivationIndex',
      type: IsarType.long,
    ),
    r'derivationPath': PropertySchema(
      id: 4,
      name: r'derivationPath',
      type: IsarType.string,
    ),
    r'firstUsedAt': PropertySchema(
      id: 5,
      name: r'firstUsedAt',
      type: IsarType.dateTime,
    ),
    r'isChange': PropertySchema(
      id: 6,
      name: r'isChange',
      type: IsarType.bool,
    ),
    r'isWatched': PropertySchema(
      id: 7,
      name: r'isWatched',
      type: IsarType.bool,
    ),
    r'label': PropertySchema(
      id: 8,
      name: r'label',
      type: IsarType.string,
    ),
    r'lastUsedAt': PropertySchema(
      id: 9,
      name: r'lastUsedAt',
      type: IsarType.dateTime,
    ),
    r'purpose': PropertySchema(
      id: 10,
      name: r'purpose',
      type: IsarType.string,
    ),
    r'scriptType': PropertySchema(
      id: 11,
      name: r'scriptType',
      type: IsarType.string,
    ),
    r'usageCount': PropertySchema(
      id: 12,
      name: r'usageCount',
      type: IsarType.long,
    ),
    r'walletId': PropertySchema(
      id: 13,
      name: r'walletId',
      type: IsarType.string,
    )
  },
  estimateSize: _addressEntityEstimateSize,
  serialize: _addressEntitySerialize,
  deserialize: _addressEntityDeserialize,
  deserializeProp: _addressEntityDeserializeProp,
  idName: r'id',
  indexes: {
    r'walletId': IndexSchema(
      id: -1783113319798776304,
      name: r'walletId',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'walletId',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'address': IndexSchema(
      id: -259407546592846288,
      name: r'address',
      unique: true,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'address',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'derivationIndex': IndexSchema(
      id: -6950711977521998012,
      name: r'derivationIndex',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'derivationIndex',
          type: IndexType.value,
          caseSensitive: false,
        )
      ],
    )
  },
  links: {},
  embeddedSchemas: {},
  getId: _addressEntityGetId,
  getLinks: _addressEntityGetLinks,
  attach: _addressEntityAttach,
  version: '3.1.0+1',
);

int _addressEntityEstimateSize(
  AddressEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.address.length * 3;
  bytesCount += 3 + object.balance.length * 3;
  {
    final value = object.derivationPath;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.label;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.purpose.length * 3;
  bytesCount += 3 + object.scriptType.length * 3;
  bytesCount += 3 + object.walletId.length * 3;
  return bytesCount;
}

void _addressEntitySerialize(
  AddressEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.address);
  writer.writeString(offsets[1], object.balance);
  writer.writeDateTime(offsets[2], object.createdAt);
  writer.writeLong(offsets[3], object.derivationIndex);
  writer.writeString(offsets[4], object.derivationPath);
  writer.writeDateTime(offsets[5], object.firstUsedAt);
  writer.writeBool(offsets[6], object.isChange);
  writer.writeBool(offsets[7], object.isWatched);
  writer.writeString(offsets[8], object.label);
  writer.writeDateTime(offsets[9], object.lastUsedAt);
  writer.writeString(offsets[10], object.purpose);
  writer.writeString(offsets[11], object.scriptType);
  writer.writeLong(offsets[12], object.usageCount);
  writer.writeString(offsets[13], object.walletId);
}

AddressEntity _addressEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = AddressEntity();
  object.address = reader.readString(offsets[0]);
  object.balance = reader.readString(offsets[1]);
  object.createdAt = reader.readDateTime(offsets[2]);
  object.derivationIndex = reader.readLongOrNull(offsets[3]);
  object.derivationPath = reader.readStringOrNull(offsets[4]);
  object.firstUsedAt = reader.readDateTimeOrNull(offsets[5]);
  object.id = id;
  object.isChange = reader.readBool(offsets[6]);
  object.isWatched = reader.readBool(offsets[7]);
  object.label = reader.readStringOrNull(offsets[8]);
  object.lastUsedAt = reader.readDateTimeOrNull(offsets[9]);
  object.purpose = reader.readString(offsets[10]);
  object.scriptType = reader.readString(offsets[11]);
  object.usageCount = reader.readLong(offsets[12]);
  object.walletId = reader.readString(offsets[13]);
  return object;
}

P _addressEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readString(offset)) as P;
    case 1:
      return (reader.readString(offset)) as P;
    case 2:
      return (reader.readDateTime(offset)) as P;
    case 3:
      return (reader.readLongOrNull(offset)) as P;
    case 4:
      return (reader.readStringOrNull(offset)) as P;
    case 5:
      return (reader.readDateTimeOrNull(offset)) as P;
    case 6:
      return (reader.readBool(offset)) as P;
    case 7:
      return (reader.readBool(offset)) as P;
    case 8:
      return (reader.readStringOrNull(offset)) as P;
    case 9:
      return (reader.readDateTimeOrNull(offset)) as P;
    case 10:
      return (reader.readString(offset)) as P;
    case 11:
      return (reader.readString(offset)) as P;
    case 12:
      return (reader.readLong(offset)) as P;
    case 13:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _addressEntityGetId(AddressEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _addressEntityGetLinks(AddressEntity object) {
  return [];
}

void _addressEntityAttach(
    IsarCollection<dynamic> col, Id id, AddressEntity object) {
  object.id = id;
}

extension AddressEntityByIndex on IsarCollection<AddressEntity> {
  Future<AddressEntity?> getByAddress(String address) {
    return getByIndex(r'address', [address]);
  }

  AddressEntity? getByAddressSync(String address) {
    return getByIndexSync(r'address', [address]);
  }

  Future<bool> deleteByAddress(String address) {
    return deleteByIndex(r'address', [address]);
  }

  bool deleteByAddressSync(String address) {
    return deleteByIndexSync(r'address', [address]);
  }

  Future<List<AddressEntity?>> getAllByAddress(List<String> addressValues) {
    final values = addressValues.map((e) => [e]).toList();
    return getAllByIndex(r'address', values);
  }

  List<AddressEntity?> getAllByAddressSync(List<String> addressValues) {
    final values = addressValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'address', values);
  }

  Future<int> deleteAllByAddress(List<String> addressValues) {
    final values = addressValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'address', values);
  }

  int deleteAllByAddressSync(List<String> addressValues) {
    final values = addressValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'address', values);
  }

  Future<Id> putByAddress(AddressEntity object) {
    return putByIndex(r'address', object);
  }

  Id putByAddressSync(AddressEntity object, {bool saveLinks = true}) {
    return putByIndexSync(r'address', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByAddress(List<AddressEntity> objects) {
    return putAllByIndex(r'address', objects);
  }

  List<Id> putAllByAddressSync(List<AddressEntity> objects,
      {bool saveLinks = true}) {
    return putAllByIndexSync(r'address', objects, saveLinks: saveLinks);
  }
}

extension AddressEntityQueryWhereSort
    on QueryBuilder<AddressEntity, AddressEntity, QWhere> {
  QueryBuilder<AddressEntity, AddressEntity, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhere> anyDerivationIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'derivationIndex'),
      );
    });
  }
}

extension AddressEntityQueryWhere
    on QueryBuilder<AddressEntity, AddressEntity, QWhereClause> {
  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause> idEqualTo(
      Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause> idNotEqualTo(
      Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause> idGreaterThan(
      Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause> idLessThan(
      Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause> idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: lowerId,
        includeLower: includeLower,
        upper: upperId,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause> walletIdEqualTo(
      String walletId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'walletId',
        value: [walletId],
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause>
      walletIdNotEqualTo(String walletId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [],
              upper: [walletId],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [walletId],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [walletId],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [],
              upper: [walletId],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause> addressEqualTo(
      String address) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'address',
        value: [address],
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause>
      addressNotEqualTo(String address) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'address',
              lower: [],
              upper: [address],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'address',
              lower: [address],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'address',
              lower: [address],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'address',
              lower: [],
              upper: [address],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause>
      derivationIndexIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'derivationIndex',
        value: [null],
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause>
      derivationIndexIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'derivationIndex',
        lower: [null],
        includeLower: false,
        upper: [],
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause>
      derivationIndexEqualTo(int? derivationIndex) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'derivationIndex',
        value: [derivationIndex],
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause>
      derivationIndexNotEqualTo(int? derivationIndex) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'derivationIndex',
              lower: [],
              upper: [derivationIndex],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'derivationIndex',
              lower: [derivationIndex],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'derivationIndex',
              lower: [derivationIndex],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'derivationIndex',
              lower: [],
              upper: [derivationIndex],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause>
      derivationIndexGreaterThan(
    int? derivationIndex, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'derivationIndex',
        lower: [derivationIndex],
        includeLower: include,
        upper: [],
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause>
      derivationIndexLessThan(
    int? derivationIndex, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'derivationIndex',
        lower: [],
        upper: [derivationIndex],
        includeUpper: include,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterWhereClause>
      derivationIndexBetween(
    int? lowerDerivationIndex,
    int? upperDerivationIndex, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'derivationIndex',
        lower: [lowerDerivationIndex],
        includeLower: includeLower,
        upper: [upperDerivationIndex],
        includeUpper: includeUpper,
      ));
    });
  }
}

extension AddressEntityQueryFilter
    on QueryBuilder<AddressEntity, AddressEntity, QFilterCondition> {
  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      addressEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      addressGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      addressLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      addressBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'address',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      addressStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      addressEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      addressContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      addressMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'address',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      addressIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'address',
        value: '',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      addressIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'address',
        value: '',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      balanceEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'balance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      balanceGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'balance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      balanceLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'balance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      balanceBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'balance',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      balanceStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'balance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      balanceEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'balance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      balanceContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'balance',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      balanceMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'balance',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      balanceIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'balance',
        value: '',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      balanceIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'balance',
        value: '',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      createdAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      createdAtGreaterThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      createdAtLessThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      createdAtBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'createdAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationIndexIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'derivationIndex',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationIndexIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'derivationIndex',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationIndexEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'derivationIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationIndexGreaterThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'derivationIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationIndexLessThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'derivationIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationIndexBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'derivationIndex',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationPathIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'derivationPath',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationPathIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'derivationPath',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationPathEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'derivationPath',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationPathGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'derivationPath',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationPathLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'derivationPath',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationPathBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'derivationPath',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationPathStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'derivationPath',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationPathEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'derivationPath',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationPathContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'derivationPath',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationPathMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'derivationPath',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationPathIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'derivationPath',
        value: '',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      derivationPathIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'derivationPath',
        value: '',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      firstUsedAtIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'firstUsedAt',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      firstUsedAtIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'firstUsedAt',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      firstUsedAtEqualTo(DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'firstUsedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      firstUsedAtGreaterThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'firstUsedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      firstUsedAtLessThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'firstUsedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      firstUsedAtBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'firstUsedAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition> idEqualTo(
      Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      idGreaterThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition> idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition> idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'id',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      isChangeEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'isChange',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      isWatchedEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'isWatched',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      labelIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'label',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      labelIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'label',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      labelEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'label',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      labelGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'label',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      labelLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'label',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      labelBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'label',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      labelStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'label',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      labelEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'label',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      labelContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'label',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      labelMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'label',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      labelIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'label',
        value: '',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      labelIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'label',
        value: '',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      lastUsedAtIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'lastUsedAt',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      lastUsedAtIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'lastUsedAt',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      lastUsedAtEqualTo(DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'lastUsedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      lastUsedAtGreaterThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'lastUsedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      lastUsedAtLessThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'lastUsedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      lastUsedAtBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'lastUsedAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      purposeEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'purpose',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      purposeGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'purpose',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      purposeLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'purpose',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      purposeBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'purpose',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      purposeStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'purpose',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      purposeEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'purpose',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      purposeContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'purpose',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      purposeMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'purpose',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      purposeIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'purpose',
        value: '',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      purposeIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'purpose',
        value: '',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      scriptTypeEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'scriptType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      scriptTypeGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'scriptType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      scriptTypeLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'scriptType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      scriptTypeBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'scriptType',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      scriptTypeStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'scriptType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      scriptTypeEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'scriptType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      scriptTypeContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'scriptType',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      scriptTypeMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'scriptType',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      scriptTypeIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'scriptType',
        value: '',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      scriptTypeIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'scriptType',
        value: '',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      usageCountEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'usageCount',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      usageCountGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'usageCount',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      usageCountLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'usageCount',
        value: value,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      usageCountBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'usageCount',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      walletIdEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      walletIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      walletIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      walletIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'walletId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      walletIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      walletIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      walletIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      walletIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'walletId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      walletIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: '',
      ));
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterFilterCondition>
      walletIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'walletId',
        value: '',
      ));
    });
  }
}

extension AddressEntityQueryObject
    on QueryBuilder<AddressEntity, AddressEntity, QFilterCondition> {}

extension AddressEntityQueryLinks
    on QueryBuilder<AddressEntity, AddressEntity, QFilterCondition> {}

extension AddressEntityQuerySortBy
    on QueryBuilder<AddressEntity, AddressEntity, QSortBy> {
  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByAddress() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByAddressDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByBalance() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'balance', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByBalanceDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'balance', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      sortByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      sortByDerivationIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'derivationIndex', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      sortByDerivationIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'derivationIndex', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      sortByDerivationPath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'derivationPath', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      sortByDerivationPathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'derivationPath', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByFirstUsedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'firstUsedAt', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      sortByFirstUsedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'firstUsedAt', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByIsChange() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isChange', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      sortByIsChangeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isChange', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByIsWatched() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isWatched', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      sortByIsWatchedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isWatched', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByLabel() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'label', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByLabelDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'label', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByLastUsedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastUsedAt', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      sortByLastUsedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastUsedAt', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByPurpose() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'purpose', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByPurposeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'purpose', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByScriptType() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scriptType', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      sortByScriptTypeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scriptType', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByUsageCount() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'usageCount', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      sortByUsageCountDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'usageCount', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> sortByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      sortByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }
}

extension AddressEntityQuerySortThenBy
    on QueryBuilder<AddressEntity, AddressEntity, QSortThenBy> {
  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByAddress() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByAddressDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByBalance() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'balance', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByBalanceDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'balance', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      thenByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      thenByDerivationIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'derivationIndex', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      thenByDerivationIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'derivationIndex', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      thenByDerivationPath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'derivationPath', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      thenByDerivationPathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'derivationPath', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByFirstUsedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'firstUsedAt', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      thenByFirstUsedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'firstUsedAt', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByIsChange() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isChange', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      thenByIsChangeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isChange', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByIsWatched() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isWatched', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      thenByIsWatchedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isWatched', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByLabel() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'label', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByLabelDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'label', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByLastUsedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastUsedAt', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      thenByLastUsedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastUsedAt', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByPurpose() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'purpose', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByPurposeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'purpose', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByScriptType() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scriptType', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      thenByScriptTypeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scriptType', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByUsageCount() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'usageCount', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      thenByUsageCountDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'usageCount', Sort.desc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy> thenByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QAfterSortBy>
      thenByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }
}

extension AddressEntityQueryWhereDistinct
    on QueryBuilder<AddressEntity, AddressEntity, QDistinct> {
  QueryBuilder<AddressEntity, AddressEntity, QDistinct> distinctByAddress(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'address', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QDistinct> distinctByBalance(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'balance', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QDistinct> distinctByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'createdAt');
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QDistinct>
      distinctByDerivationIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'derivationIndex');
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QDistinct>
      distinctByDerivationPath({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'derivationPath',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QDistinct>
      distinctByFirstUsedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'firstUsedAt');
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QDistinct> distinctByIsChange() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'isChange');
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QDistinct> distinctByIsWatched() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'isWatched');
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QDistinct> distinctByLabel(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'label', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QDistinct> distinctByLastUsedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'lastUsedAt');
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QDistinct> distinctByPurpose(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'purpose', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QDistinct> distinctByScriptType(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'scriptType', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QDistinct> distinctByUsageCount() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'usageCount');
    });
  }

  QueryBuilder<AddressEntity, AddressEntity, QDistinct> distinctByWalletId(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'walletId', caseSensitive: caseSensitive);
    });
  }
}

extension AddressEntityQueryProperty
    on QueryBuilder<AddressEntity, AddressEntity, QQueryProperty> {
  QueryBuilder<AddressEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<AddressEntity, String, QQueryOperations> addressProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'address');
    });
  }

  QueryBuilder<AddressEntity, String, QQueryOperations> balanceProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'balance');
    });
  }

  QueryBuilder<AddressEntity, DateTime, QQueryOperations> createdAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'createdAt');
    });
  }

  QueryBuilder<AddressEntity, int?, QQueryOperations>
      derivationIndexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'derivationIndex');
    });
  }

  QueryBuilder<AddressEntity, String?, QQueryOperations>
      derivationPathProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'derivationPath');
    });
  }

  QueryBuilder<AddressEntity, DateTime?, QQueryOperations>
      firstUsedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'firstUsedAt');
    });
  }

  QueryBuilder<AddressEntity, bool, QQueryOperations> isChangeProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'isChange');
    });
  }

  QueryBuilder<AddressEntity, bool, QQueryOperations> isWatchedProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'isWatched');
    });
  }

  QueryBuilder<AddressEntity, String?, QQueryOperations> labelProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'label');
    });
  }

  QueryBuilder<AddressEntity, DateTime?, QQueryOperations>
      lastUsedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'lastUsedAt');
    });
  }

  QueryBuilder<AddressEntity, String, QQueryOperations> purposeProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'purpose');
    });
  }

  QueryBuilder<AddressEntity, String, QQueryOperations> scriptTypeProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'scriptType');
    });
  }

  QueryBuilder<AddressEntity, int, QQueryOperations> usageCountProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'usageCount');
    });
  }

  QueryBuilder<AddressEntity, String, QQueryOperations> walletIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'walletId');
    });
  }
}

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetTransactionAddressEntityCollection on Isar {
  IsarCollection<TransactionAddressEntity> get transactionAddressEntitys =>
      this.collection();
}

const TransactionAddressEntitySchema = CollectionSchema(
  name: r'TransactionAddressEntity',
  id: 4435734835252030740,
  properties: {
    r'address': PropertySchema(
      id: 0,
      name: r'address',
      type: IsarType.string,
    ),
    r'amount': PropertySchema(
      id: 1,
      name: r'amount',
      type: IsarType.string,
    ),
    r'createdAt': PropertySchema(
      id: 2,
      name: r'createdAt',
      type: IsarType.dateTime,
    ),
    r'direction': PropertySchema(
      id: 3,
      name: r'direction',
      type: IsarType.string,
    ),
    r'txid': PropertySchema(
      id: 4,
      name: r'txid',
      type: IsarType.string,
    ),
    r'vin': PropertySchema(
      id: 5,
      name: r'vin',
      type: IsarType.long,
    ),
    r'vout': PropertySchema(
      id: 6,
      name: r'vout',
      type: IsarType.long,
    ),
    r'walletId': PropertySchema(
      id: 7,
      name: r'walletId',
      type: IsarType.string,
    ),
    r'walletIdAddress': PropertySchema(
      id: 8,
      name: r'walletIdAddress',
      type: IsarType.string,
    ),
    r'walletIdTxid': PropertySchema(
      id: 9,
      name: r'walletIdTxid',
      type: IsarType.string,
    )
  },
  estimateSize: _transactionAddressEntityEstimateSize,
  serialize: _transactionAddressEntitySerialize,
  deserialize: _transactionAddressEntityDeserialize,
  deserializeProp: _transactionAddressEntityDeserializeProp,
  idName: r'id',
  indexes: {
    r'walletId': IndexSchema(
      id: -1783113319798776304,
      name: r'walletId',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'walletId',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'txid': IndexSchema(
      id: 7339874292043634331,
      name: r'txid',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'txid',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'address': IndexSchema(
      id: -259407546592846288,
      name: r'address',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'address',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'direction': IndexSchema(
      id: -4378097054569869819,
      name: r'direction',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'direction',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'walletIdAddress_address': IndexSchema(
      id: -4045275986138552383,
      name: r'walletIdAddress_address',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'walletIdAddress',
          type: IndexType.hash,
          caseSensitive: true,
        ),
        IndexPropertySchema(
          name: r'address',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'walletIdTxid_txid': IndexSchema(
      id: 4199928552273787480,
      name: r'walletIdTxid_txid',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'walletIdTxid',
          type: IndexType.hash,
          caseSensitive: true,
        ),
        IndexPropertySchema(
          name: r'txid',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    )
  },
  links: {},
  embeddedSchemas: {},
  getId: _transactionAddressEntityGetId,
  getLinks: _transactionAddressEntityGetLinks,
  attach: _transactionAddressEntityAttach,
  version: '3.1.0+1',
);

int _transactionAddressEntityEstimateSize(
  TransactionAddressEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.address.length * 3;
  bytesCount += 3 + object.amount.length * 3;
  bytesCount += 3 + object.direction.length * 3;
  bytesCount += 3 + object.txid.length * 3;
  bytesCount += 3 + object.walletId.length * 3;
  bytesCount += 3 + object.walletIdAddress.length * 3;
  bytesCount += 3 + object.walletIdTxid.length * 3;
  return bytesCount;
}

void _transactionAddressEntitySerialize(
  TransactionAddressEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.address);
  writer.writeString(offsets[1], object.amount);
  writer.writeDateTime(offsets[2], object.createdAt);
  writer.writeString(offsets[3], object.direction);
  writer.writeString(offsets[4], object.txid);
  writer.writeLong(offsets[5], object.vin);
  writer.writeLong(offsets[6], object.vout);
  writer.writeString(offsets[7], object.walletId);
  writer.writeString(offsets[8], object.walletIdAddress);
  writer.writeString(offsets[9], object.walletIdTxid);
}

TransactionAddressEntity _transactionAddressEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = TransactionAddressEntity();
  object.address = reader.readString(offsets[0]);
  object.amount = reader.readString(offsets[1]);
  object.createdAt = reader.readDateTime(offsets[2]);
  object.direction = reader.readString(offsets[3]);
  object.id = id;
  object.txid = reader.readString(offsets[4]);
  object.vin = reader.readLongOrNull(offsets[5]);
  object.vout = reader.readLongOrNull(offsets[6]);
  object.walletId = reader.readString(offsets[7]);
  object.walletIdAddress = reader.readString(offsets[8]);
  object.walletIdTxid = reader.readString(offsets[9]);
  return object;
}

P _transactionAddressEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readString(offset)) as P;
    case 1:
      return (reader.readString(offset)) as P;
    case 2:
      return (reader.readDateTime(offset)) as P;
    case 3:
      return (reader.readString(offset)) as P;
    case 4:
      return (reader.readString(offset)) as P;
    case 5:
      return (reader.readLongOrNull(offset)) as P;
    case 6:
      return (reader.readLongOrNull(offset)) as P;
    case 7:
      return (reader.readString(offset)) as P;
    case 8:
      return (reader.readString(offset)) as P;
    case 9:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _transactionAddressEntityGetId(TransactionAddressEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _transactionAddressEntityGetLinks(
    TransactionAddressEntity object) {
  return [];
}

void _transactionAddressEntityAttach(
    IsarCollection<dynamic> col, Id id, TransactionAddressEntity object) {
  object.id = id;
}

extension TransactionAddressEntityQueryWhereSort on QueryBuilder<
    TransactionAddressEntity, TransactionAddressEntity, QWhere> {
  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterWhere>
      anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension TransactionAddressEntityQueryWhere on QueryBuilder<
    TransactionAddressEntity, TransactionAddressEntity, QWhereClause> {
  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> idNotEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> idLessThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: lowerId,
        includeLower: includeLower,
        upper: upperId,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> walletIdEqualTo(String walletId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'walletId',
        value: [walletId],
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> walletIdNotEqualTo(String walletId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [],
              upper: [walletId],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [walletId],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [walletId],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [],
              upper: [walletId],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> txidEqualTo(String txid) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'txid',
        value: [txid],
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> txidNotEqualTo(String txid) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [],
              upper: [txid],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [txid],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [txid],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'txid',
              lower: [],
              upper: [txid],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> addressEqualTo(String address) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'address',
        value: [address],
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> addressNotEqualTo(String address) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'address',
              lower: [],
              upper: [address],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'address',
              lower: [address],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'address',
              lower: [address],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'address',
              lower: [],
              upper: [address],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> directionEqualTo(String direction) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'direction',
        value: [direction],
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> directionNotEqualTo(String direction) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'direction',
              lower: [],
              upper: [direction],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'direction',
              lower: [direction],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'direction',
              lower: [direction],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'direction',
              lower: [],
              upper: [direction],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterWhereClause>
      walletIdAddressEqualToAnyAddress(String walletIdAddress) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'walletIdAddress_address',
        value: [walletIdAddress],
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterWhereClause>
      walletIdAddressNotEqualToAnyAddress(String walletIdAddress) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdAddress_address',
              lower: [],
              upper: [walletIdAddress],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdAddress_address',
              lower: [walletIdAddress],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdAddress_address',
              lower: [walletIdAddress],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdAddress_address',
              lower: [],
              upper: [walletIdAddress],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterWhereClause>
      walletIdAddressAddressEqualTo(String walletIdAddress, String address) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'walletIdAddress_address',
        value: [walletIdAddress, address],
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterWhereClause>
      walletIdAddressEqualToAddressNotEqualTo(
          String walletIdAddress, String address) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdAddress_address',
              lower: [walletIdAddress],
              upper: [walletIdAddress, address],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdAddress_address',
              lower: [walletIdAddress, address],
              includeLower: false,
              upper: [walletIdAddress],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdAddress_address',
              lower: [walletIdAddress, address],
              includeLower: false,
              upper: [walletIdAddress],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdAddress_address',
              lower: [walletIdAddress],
              upper: [walletIdAddress, address],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> walletIdTxidEqualToAnyTxid(String walletIdTxid) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'walletIdTxid_txid',
        value: [walletIdTxid],
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterWhereClause> walletIdTxidNotEqualToAnyTxid(String walletIdTxid) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdTxid_txid',
              lower: [],
              upper: [walletIdTxid],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdTxid_txid',
              lower: [walletIdTxid],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdTxid_txid',
              lower: [walletIdTxid],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdTxid_txid',
              lower: [],
              upper: [walletIdTxid],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterWhereClause>
      walletIdTxidTxidEqualTo(String walletIdTxid, String txid) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'walletIdTxid_txid',
        value: [walletIdTxid, txid],
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterWhereClause>
      walletIdTxidEqualToTxidNotEqualTo(String walletIdTxid, String txid) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdTxid_txid',
              lower: [walletIdTxid],
              upper: [walletIdTxid, txid],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdTxid_txid',
              lower: [walletIdTxid, txid],
              includeLower: false,
              upper: [walletIdTxid],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdTxid_txid',
              lower: [walletIdTxid, txid],
              includeLower: false,
              upper: [walletIdTxid],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletIdTxid_txid',
              lower: [walletIdTxid],
              upper: [walletIdTxid, txid],
              includeUpper: false,
            ));
      }
    });
  }
}

extension TransactionAddressEntityQueryFilter on QueryBuilder<
    TransactionAddressEntity, TransactionAddressEntity, QFilterCondition> {
  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> addressEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> addressGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> addressLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> addressBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'address',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> addressStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> addressEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterFilterCondition>
      addressContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'address',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterFilterCondition>
      addressMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'address',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> addressIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'address',
        value: '',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> addressIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'address',
        value: '',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> amountEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'amount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> amountGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'amount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> amountLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'amount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> amountBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'amount',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> amountStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'amount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> amountEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'amount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterFilterCondition>
      amountContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'amount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterFilterCondition>
      amountMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'amount',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> amountIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'amount',
        value: '',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> amountIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'amount',
        value: '',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> createdAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> createdAtGreaterThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> createdAtLessThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> createdAtBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'createdAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> directionEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'direction',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> directionGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'direction',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> directionLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'direction',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> directionBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'direction',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> directionStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'direction',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> directionEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'direction',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterFilterCondition>
      directionContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'direction',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterFilterCondition>
      directionMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'direction',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> directionIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'direction',
        value: '',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> directionIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'direction',
        value: '',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> idGreaterThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'id',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> txidEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> txidGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> txidLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> txidBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'txid',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> txidStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> txidEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterFilterCondition>
      txidContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'txid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterFilterCondition>
      txidMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'txid',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> txidIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'txid',
        value: '',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> txidIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'txid',
        value: '',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> vinIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'vin',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> vinIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'vin',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> vinEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'vin',
        value: value,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> vinGreaterThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'vin',
        value: value,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> vinLessThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'vin',
        value: value,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> vinBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'vin',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> voutIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'vout',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> voutIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'vout',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> voutEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'vout',
        value: value,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> voutGreaterThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'vout',
        value: value,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> voutLessThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'vout',
        value: value,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> voutBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'vout',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'walletId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterFilterCondition>
      walletIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterFilterCondition>
      walletIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'walletId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: '',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'walletId',
        value: '',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdAddressEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletIdAddress',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdAddressGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'walletIdAddress',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdAddressLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'walletIdAddress',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdAddressBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'walletIdAddress',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdAddressStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'walletIdAddress',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdAddressEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'walletIdAddress',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterFilterCondition>
      walletIdAddressContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'walletIdAddress',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterFilterCondition>
      walletIdAddressMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'walletIdAddress',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdAddressIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletIdAddress',
        value: '',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdAddressIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'walletIdAddress',
        value: '',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdTxidEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletIdTxid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdTxidGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'walletIdTxid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdTxidLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'walletIdTxid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdTxidBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'walletIdTxid',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdTxidStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'walletIdTxid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdTxidEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'walletIdTxid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterFilterCondition>
      walletIdTxidContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'walletIdTxid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
          QAfterFilterCondition>
      walletIdTxidMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'walletIdTxid',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdTxidIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletIdTxid',
        value: '',
      ));
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity,
      QAfterFilterCondition> walletIdTxidIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'walletIdTxid',
        value: '',
      ));
    });
  }
}

extension TransactionAddressEntityQueryObject on QueryBuilder<
    TransactionAddressEntity, TransactionAddressEntity, QFilterCondition> {}

extension TransactionAddressEntityQueryLinks on QueryBuilder<
    TransactionAddressEntity, TransactionAddressEntity, QFilterCondition> {}

extension TransactionAddressEntityQuerySortBy on QueryBuilder<
    TransactionAddressEntity, TransactionAddressEntity, QSortBy> {
  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByAddress() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByAddressDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByAmount() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'amount', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByAmountDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'amount', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByDirection() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'direction', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByDirectionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'direction', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByTxid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByTxidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByVin() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'vin', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByVinDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'vin', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByVout() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'vout', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByVoutDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'vout', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByWalletIdAddress() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletIdAddress', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByWalletIdAddressDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletIdAddress', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByWalletIdTxid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletIdTxid', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      sortByWalletIdTxidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletIdTxid', Sort.desc);
    });
  }
}

extension TransactionAddressEntityQuerySortThenBy on QueryBuilder<
    TransactionAddressEntity, TransactionAddressEntity, QSortThenBy> {
  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByAddress() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByAddressDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'address', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByAmount() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'amount', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByAmountDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'amount', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByDirection() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'direction', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByDirectionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'direction', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByTxid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByTxidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'txid', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByVin() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'vin', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByVinDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'vin', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByVout() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'vout', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByVoutDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'vout', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByWalletIdAddress() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletIdAddress', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByWalletIdAddressDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletIdAddress', Sort.desc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByWalletIdTxid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletIdTxid', Sort.asc);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QAfterSortBy>
      thenByWalletIdTxidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletIdTxid', Sort.desc);
    });
  }
}

extension TransactionAddressEntityQueryWhereDistinct on QueryBuilder<
    TransactionAddressEntity, TransactionAddressEntity, QDistinct> {
  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QDistinct>
      distinctByAddress({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'address', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QDistinct>
      distinctByAmount({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'amount', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QDistinct>
      distinctByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'createdAt');
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QDistinct>
      distinctByDirection({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'direction', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QDistinct>
      distinctByTxid({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'txid', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QDistinct>
      distinctByVin() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'vin');
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QDistinct>
      distinctByVout() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'vout');
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QDistinct>
      distinctByWalletId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'walletId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QDistinct>
      distinctByWalletIdAddress({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'walletIdAddress',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<TransactionAddressEntity, TransactionAddressEntity, QDistinct>
      distinctByWalletIdTxid({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'walletIdTxid', caseSensitive: caseSensitive);
    });
  }
}

extension TransactionAddressEntityQueryProperty on QueryBuilder<
    TransactionAddressEntity, TransactionAddressEntity, QQueryProperty> {
  QueryBuilder<TransactionAddressEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<TransactionAddressEntity, String, QQueryOperations>
      addressProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'address');
    });
  }

  QueryBuilder<TransactionAddressEntity, String, QQueryOperations>
      amountProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'amount');
    });
  }

  QueryBuilder<TransactionAddressEntity, DateTime, QQueryOperations>
      createdAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'createdAt');
    });
  }

  QueryBuilder<TransactionAddressEntity, String, QQueryOperations>
      directionProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'direction');
    });
  }

  QueryBuilder<TransactionAddressEntity, String, QQueryOperations>
      txidProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'txid');
    });
  }

  QueryBuilder<TransactionAddressEntity, int?, QQueryOperations> vinProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'vin');
    });
  }

  QueryBuilder<TransactionAddressEntity, int?, QQueryOperations>
      voutProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'vout');
    });
  }

  QueryBuilder<TransactionAddressEntity, String, QQueryOperations>
      walletIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'walletId');
    });
  }

  QueryBuilder<TransactionAddressEntity, String, QQueryOperations>
      walletIdAddressProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'walletIdAddress');
    });
  }

  QueryBuilder<TransactionAddressEntity, String, QQueryOperations>
      walletIdTxidProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'walletIdTxid');
    });
  }
}

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetInvoiceEntityCollection on Isar {
  IsarCollection<InvoiceEntity> get invoiceEntitys => this.collection();
}

const InvoiceEntitySchema = CollectionSchema(
  name: r'InvoiceEntity',
  id: 7758162599778414987,
  properties: {
    r'addressesJson': PropertySchema(
      id: 0,
      name: r'addressesJson',
      type: IsarType.string,
    ),
    r'amount': PropertySchema(
      id: 1,
      name: r'amount',
      type: IsarType.string,
    ),
    r'amountReceived': PropertySchema(
      id: 2,
      name: r'amountReceived',
      type: IsarType.string,
    ),
    r'createdAt': PropertySchema(
      id: 3,
      name: r'createdAt',
      type: IsarType.dateTime,
    ),
    r'description': PropertySchema(
      id: 4,
      name: r'description',
      type: IsarType.string,
    ),
    r'expiresAt': PropertySchema(
      id: 5,
      name: r'expiresAt',
      type: IsarType.dateTime,
    ),
    r'invoiceId': PropertySchema(
      id: 6,
      name: r'invoiceId',
      type: IsarType.string,
    ),
    r'metadataJson': PropertySchema(
      id: 7,
      name: r'metadataJson',
      type: IsarType.string,
    ),
    r'outputsJson': PropertySchema(
      id: 8,
      name: r'outputsJson',
      type: IsarType.string,
    ),
    r'paidAt': PropertySchema(
      id: 9,
      name: r'paidAt',
      type: IsarType.dateTime,
    ),
    r'paymentTxid': PropertySchema(
      id: 10,
      name: r'paymentTxid',
      type: IsarType.string,
    ),
    r'status': PropertySchema(
      id: 11,
      name: r'status',
      type: IsarType.string,
    ),
    r'walletId': PropertySchema(
      id: 12,
      name: r'walletId',
      type: IsarType.string,
    )
  },
  estimateSize: _invoiceEntityEstimateSize,
  serialize: _invoiceEntitySerialize,
  deserialize: _invoiceEntityDeserialize,
  deserializeProp: _invoiceEntityDeserializeProp,
  idName: r'id',
  indexes: {
    r'invoiceId': IndexSchema(
      id: 7861523084118270123,
      name: r'invoiceId',
      unique: true,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'invoiceId',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'walletId': IndexSchema(
      id: -1783113319798776304,
      name: r'walletId',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'walletId',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'status': IndexSchema(
      id: -107785170620420283,
      name: r'status',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'status',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'createdAt': IndexSchema(
      id: -3433535483987302584,
      name: r'createdAt',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'createdAt',
          type: IndexType.value,
          caseSensitive: false,
        )
      ],
    )
  },
  links: {},
  embeddedSchemas: {},
  getId: _invoiceEntityGetId,
  getLinks: _invoiceEntityGetLinks,
  attach: _invoiceEntityAttach,
  version: '3.1.0+1',
);

int _invoiceEntityEstimateSize(
  InvoiceEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.addressesJson.length * 3;
  bytesCount += 3 + object.amount.length * 3;
  {
    final value = object.amountReceived;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.description;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.invoiceId.length * 3;
  {
    final value = object.metadataJson;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.outputsJson;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.paymentTxid;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.status.length * 3;
  bytesCount += 3 + object.walletId.length * 3;
  return bytesCount;
}

void _invoiceEntitySerialize(
  InvoiceEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.addressesJson);
  writer.writeString(offsets[1], object.amount);
  writer.writeString(offsets[2], object.amountReceived);
  writer.writeDateTime(offsets[3], object.createdAt);
  writer.writeString(offsets[4], object.description);
  writer.writeDateTime(offsets[5], object.expiresAt);
  writer.writeString(offsets[6], object.invoiceId);
  writer.writeString(offsets[7], object.metadataJson);
  writer.writeString(offsets[8], object.outputsJson);
  writer.writeDateTime(offsets[9], object.paidAt);
  writer.writeString(offsets[10], object.paymentTxid);
  writer.writeString(offsets[11], object.status);
  writer.writeString(offsets[12], object.walletId);
}

InvoiceEntity _invoiceEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = InvoiceEntity();
  object.addressesJson = reader.readString(offsets[0]);
  object.amount = reader.readString(offsets[1]);
  object.amountReceived = reader.readStringOrNull(offsets[2]);
  object.createdAt = reader.readDateTime(offsets[3]);
  object.description = reader.readStringOrNull(offsets[4]);
  object.expiresAt = reader.readDateTimeOrNull(offsets[5]);
  object.id = id;
  object.invoiceId = reader.readString(offsets[6]);
  object.metadataJson = reader.readStringOrNull(offsets[7]);
  object.outputsJson = reader.readStringOrNull(offsets[8]);
  object.paidAt = reader.readDateTimeOrNull(offsets[9]);
  object.paymentTxid = reader.readStringOrNull(offsets[10]);
  object.status = reader.readString(offsets[11]);
  object.walletId = reader.readString(offsets[12]);
  return object;
}

P _invoiceEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readString(offset)) as P;
    case 1:
      return (reader.readString(offset)) as P;
    case 2:
      return (reader.readStringOrNull(offset)) as P;
    case 3:
      return (reader.readDateTime(offset)) as P;
    case 4:
      return (reader.readStringOrNull(offset)) as P;
    case 5:
      return (reader.readDateTimeOrNull(offset)) as P;
    case 6:
      return (reader.readString(offset)) as P;
    case 7:
      return (reader.readStringOrNull(offset)) as P;
    case 8:
      return (reader.readStringOrNull(offset)) as P;
    case 9:
      return (reader.readDateTimeOrNull(offset)) as P;
    case 10:
      return (reader.readStringOrNull(offset)) as P;
    case 11:
      return (reader.readString(offset)) as P;
    case 12:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _invoiceEntityGetId(InvoiceEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _invoiceEntityGetLinks(InvoiceEntity object) {
  return [];
}

void _invoiceEntityAttach(
    IsarCollection<dynamic> col, Id id, InvoiceEntity object) {
  object.id = id;
}

extension InvoiceEntityByIndex on IsarCollection<InvoiceEntity> {
  Future<InvoiceEntity?> getByInvoiceId(String invoiceId) {
    return getByIndex(r'invoiceId', [invoiceId]);
  }

  InvoiceEntity? getByInvoiceIdSync(String invoiceId) {
    return getByIndexSync(r'invoiceId', [invoiceId]);
  }

  Future<bool> deleteByInvoiceId(String invoiceId) {
    return deleteByIndex(r'invoiceId', [invoiceId]);
  }

  bool deleteByInvoiceIdSync(String invoiceId) {
    return deleteByIndexSync(r'invoiceId', [invoiceId]);
  }

  Future<List<InvoiceEntity?>> getAllByInvoiceId(List<String> invoiceIdValues) {
    final values = invoiceIdValues.map((e) => [e]).toList();
    return getAllByIndex(r'invoiceId', values);
  }

  List<InvoiceEntity?> getAllByInvoiceIdSync(List<String> invoiceIdValues) {
    final values = invoiceIdValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'invoiceId', values);
  }

  Future<int> deleteAllByInvoiceId(List<String> invoiceIdValues) {
    final values = invoiceIdValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'invoiceId', values);
  }

  int deleteAllByInvoiceIdSync(List<String> invoiceIdValues) {
    final values = invoiceIdValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'invoiceId', values);
  }

  Future<Id> putByInvoiceId(InvoiceEntity object) {
    return putByIndex(r'invoiceId', object);
  }

  Id putByInvoiceIdSync(InvoiceEntity object, {bool saveLinks = true}) {
    return putByIndexSync(r'invoiceId', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByInvoiceId(List<InvoiceEntity> objects) {
    return putAllByIndex(r'invoiceId', objects);
  }

  List<Id> putAllByInvoiceIdSync(List<InvoiceEntity> objects,
      {bool saveLinks = true}) {
    return putAllByIndexSync(r'invoiceId', objects, saveLinks: saveLinks);
  }
}

extension InvoiceEntityQueryWhereSort
    on QueryBuilder<InvoiceEntity, InvoiceEntity, QWhere> {
  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhere> anyCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'createdAt'),
      );
    });
  }
}

extension InvoiceEntityQueryWhere
    on QueryBuilder<InvoiceEntity, InvoiceEntity, QWhereClause> {
  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause> idEqualTo(
      Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause> idNotEqualTo(
      Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause> idGreaterThan(
      Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause> idLessThan(
      Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause> idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: lowerId,
        includeLower: includeLower,
        upper: upperId,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause>
      invoiceIdEqualTo(String invoiceId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'invoiceId',
        value: [invoiceId],
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause>
      invoiceIdNotEqualTo(String invoiceId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'invoiceId',
              lower: [],
              upper: [invoiceId],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'invoiceId',
              lower: [invoiceId],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'invoiceId',
              lower: [invoiceId],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'invoiceId',
              lower: [],
              upper: [invoiceId],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause> walletIdEqualTo(
      String walletId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'walletId',
        value: [walletId],
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause>
      walletIdNotEqualTo(String walletId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [],
              upper: [walletId],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [walletId],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [walletId],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'walletId',
              lower: [],
              upper: [walletId],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause> statusEqualTo(
      String status) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'status',
        value: [status],
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause>
      statusNotEqualTo(String status) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'status',
              lower: [],
              upper: [status],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'status',
              lower: [status],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'status',
              lower: [status],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'status',
              lower: [],
              upper: [status],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause>
      createdAtEqualTo(DateTime createdAt) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'createdAt',
        value: [createdAt],
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause>
      createdAtNotEqualTo(DateTime createdAt) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'createdAt',
              lower: [],
              upper: [createdAt],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'createdAt',
              lower: [createdAt],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'createdAt',
              lower: [createdAt],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'createdAt',
              lower: [],
              upper: [createdAt],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause>
      createdAtGreaterThan(
    DateTime createdAt, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'createdAt',
        lower: [createdAt],
        includeLower: include,
        upper: [],
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause>
      createdAtLessThan(
    DateTime createdAt, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'createdAt',
        lower: [],
        upper: [createdAt],
        includeUpper: include,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterWhereClause>
      createdAtBetween(
    DateTime lowerCreatedAt,
    DateTime upperCreatedAt, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'createdAt',
        lower: [lowerCreatedAt],
        includeLower: includeLower,
        upper: [upperCreatedAt],
        includeUpper: includeUpper,
      ));
    });
  }
}

extension InvoiceEntityQueryFilter
    on QueryBuilder<InvoiceEntity, InvoiceEntity, QFilterCondition> {
  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      addressesJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'addressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      addressesJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'addressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      addressesJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'addressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      addressesJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'addressesJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      addressesJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'addressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      addressesJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'addressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      addressesJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'addressesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      addressesJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'addressesJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      addressesJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'addressesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      addressesJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'addressesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'amount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'amount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'amount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'amount',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'amount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'amount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'amount',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'amount',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'amount',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'amount',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountReceivedIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'amountReceived',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountReceivedIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'amountReceived',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountReceivedEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'amountReceived',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountReceivedGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'amountReceived',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountReceivedLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'amountReceived',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountReceivedBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'amountReceived',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountReceivedStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'amountReceived',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountReceivedEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'amountReceived',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountReceivedContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'amountReceived',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountReceivedMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'amountReceived',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountReceivedIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'amountReceived',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      amountReceivedIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'amountReceived',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      createdAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      createdAtGreaterThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      createdAtLessThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      createdAtBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'createdAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      descriptionIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'description',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      descriptionIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'description',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      descriptionEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'description',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      descriptionGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'description',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      descriptionLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'description',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      descriptionBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'description',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      descriptionStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'description',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      descriptionEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'description',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      descriptionContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'description',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      descriptionMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'description',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      descriptionIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'description',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      descriptionIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'description',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      expiresAtIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'expiresAt',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      expiresAtIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'expiresAt',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      expiresAtEqualTo(DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'expiresAt',
        value: value,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      expiresAtGreaterThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'expiresAt',
        value: value,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      expiresAtLessThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'expiresAt',
        value: value,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      expiresAtBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'expiresAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition> idEqualTo(
      Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      idGreaterThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition> idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition> idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'id',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      invoiceIdEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'invoiceId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      invoiceIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'invoiceId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      invoiceIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'invoiceId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      invoiceIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'invoiceId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      invoiceIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'invoiceId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      invoiceIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'invoiceId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      invoiceIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'invoiceId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      invoiceIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'invoiceId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      invoiceIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'invoiceId',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      invoiceIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'invoiceId',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      metadataJsonIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'metadataJson',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      metadataJsonIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'metadataJson',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      metadataJsonEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'metadataJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      metadataJsonGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'metadataJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      metadataJsonLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'metadataJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      metadataJsonBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'metadataJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      metadataJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'metadataJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      metadataJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'metadataJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      metadataJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'metadataJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      metadataJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'metadataJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      metadataJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'metadataJson',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      metadataJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'metadataJson',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      outputsJsonIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'outputsJson',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      outputsJsonIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'outputsJson',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      outputsJsonEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'outputsJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      outputsJsonGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'outputsJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      outputsJsonLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'outputsJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      outputsJsonBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'outputsJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      outputsJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'outputsJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      outputsJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'outputsJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      outputsJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'outputsJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      outputsJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'outputsJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      outputsJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'outputsJson',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      outputsJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'outputsJson',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paidAtIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'paidAt',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paidAtIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'paidAt',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paidAtEqualTo(DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'paidAt',
        value: value,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paidAtGreaterThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'paidAt',
        value: value,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paidAtLessThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'paidAt',
        value: value,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paidAtBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'paidAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paymentTxidIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'paymentTxid',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paymentTxidIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'paymentTxid',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paymentTxidEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'paymentTxid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paymentTxidGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'paymentTxid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paymentTxidLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'paymentTxid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paymentTxidBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'paymentTxid',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paymentTxidStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'paymentTxid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paymentTxidEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'paymentTxid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paymentTxidContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'paymentTxid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paymentTxidMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'paymentTxid',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paymentTxidIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'paymentTxid',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      paymentTxidIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'paymentTxid',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      statusEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      statusGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      statusLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      statusBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'status',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      statusStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      statusEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      statusContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'status',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      statusMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'status',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      statusIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'status',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      statusIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'status',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      walletIdEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      walletIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      walletIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      walletIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'walletId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      walletIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      walletIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      walletIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'walletId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      walletIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'walletId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      walletIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: '',
      ));
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterFilterCondition>
      walletIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'walletId',
        value: '',
      ));
    });
  }
}

extension InvoiceEntityQueryObject
    on QueryBuilder<InvoiceEntity, InvoiceEntity, QFilterCondition> {}

extension InvoiceEntityQueryLinks
    on QueryBuilder<InvoiceEntity, InvoiceEntity, QFilterCondition> {}

extension InvoiceEntityQuerySortBy
    on QueryBuilder<InvoiceEntity, InvoiceEntity, QSortBy> {
  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      sortByAddressesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'addressesJson', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      sortByAddressesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'addressesJson', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> sortByAmount() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'amount', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> sortByAmountDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'amount', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      sortByAmountReceived() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'amountReceived', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      sortByAmountReceivedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'amountReceived', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> sortByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      sortByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> sortByDescription() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'description', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      sortByDescriptionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'description', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> sortByExpiresAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'expiresAt', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      sortByExpiresAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'expiresAt', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> sortByInvoiceId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'invoiceId', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      sortByInvoiceIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'invoiceId', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      sortByMetadataJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'metadataJson', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      sortByMetadataJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'metadataJson', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> sortByOutputsJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'outputsJson', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      sortByOutputsJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'outputsJson', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> sortByPaidAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'paidAt', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> sortByPaidAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'paidAt', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> sortByPaymentTxid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'paymentTxid', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      sortByPaymentTxidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'paymentTxid', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> sortByStatus() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> sortByStatusDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> sortByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      sortByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }
}

extension InvoiceEntityQuerySortThenBy
    on QueryBuilder<InvoiceEntity, InvoiceEntity, QSortThenBy> {
  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      thenByAddressesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'addressesJson', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      thenByAddressesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'addressesJson', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenByAmount() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'amount', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenByAmountDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'amount', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      thenByAmountReceived() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'amountReceived', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      thenByAmountReceivedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'amountReceived', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      thenByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenByDescription() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'description', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      thenByDescriptionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'description', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenByExpiresAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'expiresAt', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      thenByExpiresAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'expiresAt', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenByInvoiceId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'invoiceId', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      thenByInvoiceIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'invoiceId', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      thenByMetadataJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'metadataJson', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      thenByMetadataJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'metadataJson', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenByOutputsJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'outputsJson', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      thenByOutputsJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'outputsJson', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenByPaidAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'paidAt', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenByPaidAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'paidAt', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenByPaymentTxid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'paymentTxid', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      thenByPaymentTxidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'paymentTxid', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenByStatus() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenByStatusDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'status', Sort.desc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy> thenByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QAfterSortBy>
      thenByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }
}

extension InvoiceEntityQueryWhereDistinct
    on QueryBuilder<InvoiceEntity, InvoiceEntity, QDistinct> {
  QueryBuilder<InvoiceEntity, InvoiceEntity, QDistinct> distinctByAddressesJson(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'addressesJson',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QDistinct> distinctByAmount(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'amount', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QDistinct>
      distinctByAmountReceived({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'amountReceived',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QDistinct> distinctByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'createdAt');
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QDistinct> distinctByDescription(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'description', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QDistinct> distinctByExpiresAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'expiresAt');
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QDistinct> distinctByInvoiceId(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'invoiceId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QDistinct> distinctByMetadataJson(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'metadataJson', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QDistinct> distinctByOutputsJson(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'outputsJson', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QDistinct> distinctByPaidAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'paidAt');
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QDistinct> distinctByPaymentTxid(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'paymentTxid', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QDistinct> distinctByStatus(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'status', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<InvoiceEntity, InvoiceEntity, QDistinct> distinctByWalletId(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'walletId', caseSensitive: caseSensitive);
    });
  }
}

extension InvoiceEntityQueryProperty
    on QueryBuilder<InvoiceEntity, InvoiceEntity, QQueryProperty> {
  QueryBuilder<InvoiceEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<InvoiceEntity, String, QQueryOperations>
      addressesJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'addressesJson');
    });
  }

  QueryBuilder<InvoiceEntity, String, QQueryOperations> amountProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'amount');
    });
  }

  QueryBuilder<InvoiceEntity, String?, QQueryOperations>
      amountReceivedProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'amountReceived');
    });
  }

  QueryBuilder<InvoiceEntity, DateTime, QQueryOperations> createdAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'createdAt');
    });
  }

  QueryBuilder<InvoiceEntity, String?, QQueryOperations> descriptionProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'description');
    });
  }

  QueryBuilder<InvoiceEntity, DateTime?, QQueryOperations> expiresAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'expiresAt');
    });
  }

  QueryBuilder<InvoiceEntity, String, QQueryOperations> invoiceIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'invoiceId');
    });
  }

  QueryBuilder<InvoiceEntity, String?, QQueryOperations>
      metadataJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'metadataJson');
    });
  }

  QueryBuilder<InvoiceEntity, String?, QQueryOperations> outputsJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'outputsJson');
    });
  }

  QueryBuilder<InvoiceEntity, DateTime?, QQueryOperations> paidAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'paidAt');
    });
  }

  QueryBuilder<InvoiceEntity, String?, QQueryOperations> paymentTxidProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'paymentTxid');
    });
  }

  QueryBuilder<InvoiceEntity, String, QQueryOperations> statusProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'status');
    });
  }

  QueryBuilder<InvoiceEntity, String, QQueryOperations> walletIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'walletId');
    });
  }
}
