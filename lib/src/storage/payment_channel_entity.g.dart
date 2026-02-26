// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'payment_channel_entity.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetPaymentChannelEntityCollection on Isar {
  IsarCollection<PaymentChannelEntity> get paymentChannelEntitys =>
      this.collection();
}

const PaymentChannelEntitySchema = CollectionSchema(
  name: r'PaymentChannelEntity',
  id: -7955452565994288220,
  properties: {
    r'channelId': PropertySchema(
      id: 0,
      name: r'channelId',
      type: IsarType.string,
    ),
    r'clientAddressB58': PropertySchema(
      id: 1,
      name: r'clientAddressB58',
      type: IsarType.string,
    ),
    r'clientBalanceSats': PropertySchema(
      id: 2,
      name: r'clientBalanceSats',
      type: IsarType.string,
    ),
    r'clientPeerId': PropertySchema(
      id: 3,
      name: r'clientPeerId',
      type: IsarType.string,
    ),
    r'clientPubKeyHex': PropertySchema(
      id: 4,
      name: r'clientPubKeyHex',
      type: IsarType.string,
    ),
    r'closedAt': PropertySchema(
      id: 5,
      name: r'closedAt',
      type: IsarType.dateTime,
    ),
    r'context': PropertySchema(
      id: 6,
      name: r'context',
      type: IsarType.string,
    ),
    r'createdAt': PropertySchema(
      id: 7,
      name: r'createdAt',
      type: IsarType.dateTime,
    ),
    r'errorMessage': PropertySchema(
      id: 8,
      name: r'errorMessage',
      type: IsarType.string,
    ),
    r'fundingAmountSats': PropertySchema(
      id: 9,
      name: r'fundingAmountSats',
      type: IsarType.string,
    ),
    r'fundingAncestorTxids': PropertySchema(
      id: 10,
      name: r'fundingAncestorTxids',
      type: IsarType.stringList,
    ),
    r'fundingOutputIndex': PropertySchema(
      id: 11,
      name: r'fundingOutputIndex',
      type: IsarType.long,
    ),
    r'fundingTxHex': PropertySchema(
      id: 12,
      name: r'fundingTxHex',
      type: IsarType.string,
    ),
    r'fundingTxId': PropertySchema(
      id: 13,
      name: r'fundingTxId',
      type: IsarType.string,
    ),
    r'hasFundingMerkleProof': PropertySchema(
      id: 14,
      name: r'hasFundingMerkleProof',
      type: IsarType.bool,
    ),
    r'latestPaymentTxHex': PropertySchema(
      id: 15,
      name: r'latestPaymentTxHex',
      type: IsarType.string,
    ),
    r'latestPaymentTxId': PropertySchema(
      id: 16,
      name: r'latestPaymentTxId',
      type: IsarType.string,
    ),
    r'latestSequenceNumber': PropertySchema(
      id: 17,
      name: r'latestSequenceNumber',
      type: IsarType.long,
    ),
    r'lockTimeUnix': PropertySchema(
      id: 18,
      name: r'lockTimeUnix',
      type: IsarType.long,
    ),
    r'refundClientSigHex': PropertySchema(
      id: 19,
      name: r'refundClientSigHex',
      type: IsarType.string,
    ),
    r'refundServerSigHex': PropertySchema(
      id: 20,
      name: r'refundServerSigHex',
      type: IsarType.string,
    ),
    r'refundTxHex': PropertySchema(
      id: 21,
      name: r'refundTxHex',
      type: IsarType.string,
    ),
    r'role': PropertySchema(
      id: 22,
      name: r'role',
      type: IsarType.string,
    ),
    r'serverAddressB58': PropertySchema(
      id: 23,
      name: r'serverAddressB58',
      type: IsarType.string,
    ),
    r'serverBalanceSats': PropertySchema(
      id: 24,
      name: r'serverBalanceSats',
      type: IsarType.string,
    ),
    r'serverPeerId': PropertySchema(
      id: 25,
      name: r'serverPeerId',
      type: IsarType.string,
    ),
    r'serverPubKeyHex': PropertySchema(
      id: 26,
      name: r'serverPubKeyHex',
      type: IsarType.string,
    ),
    r'settlementTxId': PropertySchema(
      id: 27,
      name: r'settlementTxId',
      type: IsarType.string,
    ),
    r'state': PropertySchema(
      id: 28,
      name: r'state',
      type: IsarType.string,
    ),
    r'walletId': PropertySchema(
      id: 29,
      name: r'walletId',
      type: IsarType.string,
    )
  },
  estimateSize: _paymentChannelEntityEstimateSize,
  serialize: _paymentChannelEntitySerialize,
  deserialize: _paymentChannelEntityDeserialize,
  deserializeProp: _paymentChannelEntityDeserializeProp,
  idName: r'id',
  indexes: {
    r'channelId': IndexSchema(
      id: -8352446570702114471,
      name: r'channelId',
      unique: true,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'channelId',
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
    r'clientPeerId': IndexSchema(
      id: 9188496923513422730,
      name: r'clientPeerId',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'clientPeerId',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'serverPeerId': IndexSchema(
      id: -272359649795454624,
      name: r'serverPeerId',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'serverPeerId',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    ),
    r'state': IndexSchema(
      id: 7917036384617311412,
      name: r'state',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'state',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    )
  },
  links: {},
  embeddedSchemas: {},
  getId: _paymentChannelEntityGetId,
  getLinks: _paymentChannelEntityGetLinks,
  attach: _paymentChannelEntityAttach,
  version: '3.1.0+1',
);

int _paymentChannelEntityEstimateSize(
  PaymentChannelEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.channelId.length * 3;
  {
    final value = object.clientAddressB58;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.clientBalanceSats.length * 3;
  bytesCount += 3 + object.clientPeerId.length * 3;
  bytesCount += 3 + object.clientPubKeyHex.length * 3;
  {
    final value = object.context;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.errorMessage;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.fundingAmountSats.length * 3;
  bytesCount += 3 + object.fundingAncestorTxids.length * 3;
  {
    for (var i = 0; i < object.fundingAncestorTxids.length; i++) {
      final value = object.fundingAncestorTxids[i];
      bytesCount += value.length * 3;
    }
  }
  {
    final value = object.fundingTxHex;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.fundingTxId;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.latestPaymentTxHex;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.latestPaymentTxId;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.refundClientSigHex;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.refundServerSigHex;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.refundTxHex;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.role.length * 3;
  {
    final value = object.serverAddressB58;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.serverBalanceSats.length * 3;
  bytesCount += 3 + object.serverPeerId.length * 3;
  bytesCount += 3 + object.serverPubKeyHex.length * 3;
  {
    final value = object.settlementTxId;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.state.length * 3;
  bytesCount += 3 + object.walletId.length * 3;
  return bytesCount;
}

void _paymentChannelEntitySerialize(
  PaymentChannelEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.channelId);
  writer.writeString(offsets[1], object.clientAddressB58);
  writer.writeString(offsets[2], object.clientBalanceSats);
  writer.writeString(offsets[3], object.clientPeerId);
  writer.writeString(offsets[4], object.clientPubKeyHex);
  writer.writeDateTime(offsets[5], object.closedAt);
  writer.writeString(offsets[6], object.context);
  writer.writeDateTime(offsets[7], object.createdAt);
  writer.writeString(offsets[8], object.errorMessage);
  writer.writeString(offsets[9], object.fundingAmountSats);
  writer.writeStringList(offsets[10], object.fundingAncestorTxids);
  writer.writeLong(offsets[11], object.fundingOutputIndex);
  writer.writeString(offsets[12], object.fundingTxHex);
  writer.writeString(offsets[13], object.fundingTxId);
  writer.writeBool(offsets[14], object.hasFundingMerkleProof);
  writer.writeString(offsets[15], object.latestPaymentTxHex);
  writer.writeString(offsets[16], object.latestPaymentTxId);
  writer.writeLong(offsets[17], object.latestSequenceNumber);
  writer.writeLong(offsets[18], object.lockTimeUnix);
  writer.writeString(offsets[19], object.refundClientSigHex);
  writer.writeString(offsets[20], object.refundServerSigHex);
  writer.writeString(offsets[21], object.refundTxHex);
  writer.writeString(offsets[22], object.role);
  writer.writeString(offsets[23], object.serverAddressB58);
  writer.writeString(offsets[24], object.serverBalanceSats);
  writer.writeString(offsets[25], object.serverPeerId);
  writer.writeString(offsets[26], object.serverPubKeyHex);
  writer.writeString(offsets[27], object.settlementTxId);
  writer.writeString(offsets[28], object.state);
  writer.writeString(offsets[29], object.walletId);
}

PaymentChannelEntity _paymentChannelEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = PaymentChannelEntity();
  object.channelId = reader.readString(offsets[0]);
  object.clientAddressB58 = reader.readStringOrNull(offsets[1]);
  object.clientBalanceSats = reader.readString(offsets[2]);
  object.clientPeerId = reader.readString(offsets[3]);
  object.clientPubKeyHex = reader.readString(offsets[4]);
  object.closedAt = reader.readDateTimeOrNull(offsets[5]);
  object.context = reader.readStringOrNull(offsets[6]);
  object.createdAt = reader.readDateTime(offsets[7]);
  object.errorMessage = reader.readStringOrNull(offsets[8]);
  object.fundingAmountSats = reader.readString(offsets[9]);
  object.fundingAncestorTxids = reader.readStringList(offsets[10]) ?? [];
  object.fundingOutputIndex = reader.readLongOrNull(offsets[11]);
  object.fundingTxHex = reader.readStringOrNull(offsets[12]);
  object.fundingTxId = reader.readStringOrNull(offsets[13]);
  object.hasFundingMerkleProof = reader.readBool(offsets[14]);
  object.id = id;
  object.latestPaymentTxHex = reader.readStringOrNull(offsets[15]);
  object.latestPaymentTxId = reader.readStringOrNull(offsets[16]);
  object.latestSequenceNumber = reader.readLong(offsets[17]);
  object.lockTimeUnix = reader.readLong(offsets[18]);
  object.refundClientSigHex = reader.readStringOrNull(offsets[19]);
  object.refundServerSigHex = reader.readStringOrNull(offsets[20]);
  object.refundTxHex = reader.readStringOrNull(offsets[21]);
  object.role = reader.readString(offsets[22]);
  object.serverAddressB58 = reader.readStringOrNull(offsets[23]);
  object.serverBalanceSats = reader.readString(offsets[24]);
  object.serverPeerId = reader.readString(offsets[25]);
  object.serverPubKeyHex = reader.readString(offsets[26]);
  object.settlementTxId = reader.readStringOrNull(offsets[27]);
  object.state = reader.readString(offsets[28]);
  object.walletId = reader.readString(offsets[29]);
  return object;
}

P _paymentChannelEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readString(offset)) as P;
    case 1:
      return (reader.readStringOrNull(offset)) as P;
    case 2:
      return (reader.readString(offset)) as P;
    case 3:
      return (reader.readString(offset)) as P;
    case 4:
      return (reader.readString(offset)) as P;
    case 5:
      return (reader.readDateTimeOrNull(offset)) as P;
    case 6:
      return (reader.readStringOrNull(offset)) as P;
    case 7:
      return (reader.readDateTime(offset)) as P;
    case 8:
      return (reader.readStringOrNull(offset)) as P;
    case 9:
      return (reader.readString(offset)) as P;
    case 10:
      return (reader.readStringList(offset) ?? []) as P;
    case 11:
      return (reader.readLongOrNull(offset)) as P;
    case 12:
      return (reader.readStringOrNull(offset)) as P;
    case 13:
      return (reader.readStringOrNull(offset)) as P;
    case 14:
      return (reader.readBool(offset)) as P;
    case 15:
      return (reader.readStringOrNull(offset)) as P;
    case 16:
      return (reader.readStringOrNull(offset)) as P;
    case 17:
      return (reader.readLong(offset)) as P;
    case 18:
      return (reader.readLong(offset)) as P;
    case 19:
      return (reader.readStringOrNull(offset)) as P;
    case 20:
      return (reader.readStringOrNull(offset)) as P;
    case 21:
      return (reader.readStringOrNull(offset)) as P;
    case 22:
      return (reader.readString(offset)) as P;
    case 23:
      return (reader.readStringOrNull(offset)) as P;
    case 24:
      return (reader.readString(offset)) as P;
    case 25:
      return (reader.readString(offset)) as P;
    case 26:
      return (reader.readString(offset)) as P;
    case 27:
      return (reader.readStringOrNull(offset)) as P;
    case 28:
      return (reader.readString(offset)) as P;
    case 29:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _paymentChannelEntityGetId(PaymentChannelEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _paymentChannelEntityGetLinks(
    PaymentChannelEntity object) {
  return [];
}

void _paymentChannelEntityAttach(
    IsarCollection<dynamic> col, Id id, PaymentChannelEntity object) {
  object.id = id;
}

extension PaymentChannelEntityByIndex on IsarCollection<PaymentChannelEntity> {
  Future<PaymentChannelEntity?> getByChannelId(String channelId) {
    return getByIndex(r'channelId', [channelId]);
  }

  PaymentChannelEntity? getByChannelIdSync(String channelId) {
    return getByIndexSync(r'channelId', [channelId]);
  }

  Future<bool> deleteByChannelId(String channelId) {
    return deleteByIndex(r'channelId', [channelId]);
  }

  bool deleteByChannelIdSync(String channelId) {
    return deleteByIndexSync(r'channelId', [channelId]);
  }

  Future<List<PaymentChannelEntity?>> getAllByChannelId(
      List<String> channelIdValues) {
    final values = channelIdValues.map((e) => [e]).toList();
    return getAllByIndex(r'channelId', values);
  }

  List<PaymentChannelEntity?> getAllByChannelIdSync(
      List<String> channelIdValues) {
    final values = channelIdValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'channelId', values);
  }

  Future<int> deleteAllByChannelId(List<String> channelIdValues) {
    final values = channelIdValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'channelId', values);
  }

  int deleteAllByChannelIdSync(List<String> channelIdValues) {
    final values = channelIdValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'channelId', values);
  }

  Future<Id> putByChannelId(PaymentChannelEntity object) {
    return putByIndex(r'channelId', object);
  }

  Id putByChannelIdSync(PaymentChannelEntity object, {bool saveLinks = true}) {
    return putByIndexSync(r'channelId', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByChannelId(List<PaymentChannelEntity> objects) {
    return putAllByIndex(r'channelId', objects);
  }

  List<Id> putAllByChannelIdSync(List<PaymentChannelEntity> objects,
      {bool saveLinks = true}) {
    return putAllByIndexSync(r'channelId', objects, saveLinks: saveLinks);
  }
}

extension PaymentChannelEntityQueryWhereSort
    on QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QWhere> {
  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhere>
      anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension PaymentChannelEntityQueryWhere
    on QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QWhereClause> {
  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
      idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
      idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
      idLessThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
      channelIdEqualTo(String channelId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'channelId',
        value: [channelId],
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
      channelIdNotEqualTo(String channelId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'channelId',
              lower: [],
              upper: [channelId],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'channelId',
              lower: [channelId],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'channelId',
              lower: [channelId],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'channelId',
              lower: [],
              upper: [channelId],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
      walletIdEqualTo(String walletId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'walletId',
        value: [walletId],
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
      clientPeerIdEqualTo(String clientPeerId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'clientPeerId',
        value: [clientPeerId],
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
      clientPeerIdNotEqualTo(String clientPeerId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'clientPeerId',
              lower: [],
              upper: [clientPeerId],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'clientPeerId',
              lower: [clientPeerId],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'clientPeerId',
              lower: [clientPeerId],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'clientPeerId',
              lower: [],
              upper: [clientPeerId],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
      serverPeerIdEqualTo(String serverPeerId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'serverPeerId',
        value: [serverPeerId],
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
      serverPeerIdNotEqualTo(String serverPeerId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'serverPeerId',
              lower: [],
              upper: [serverPeerId],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'serverPeerId',
              lower: [serverPeerId],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'serverPeerId',
              lower: [serverPeerId],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'serverPeerId',
              lower: [],
              upper: [serverPeerId],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
      stateEqualTo(String state) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'state',
        value: [state],
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterWhereClause>
      stateNotEqualTo(String state) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'state',
              lower: [],
              upper: [state],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'state',
              lower: [state],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'state',
              lower: [state],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'state',
              lower: [],
              upper: [state],
              includeUpper: false,
            ));
      }
    });
  }
}

extension PaymentChannelEntityQueryFilter on QueryBuilder<PaymentChannelEntity,
    PaymentChannelEntity, QFilterCondition> {
  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> channelIdEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'channelId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> channelIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'channelId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> channelIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'channelId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> channelIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'channelId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> channelIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'channelId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> channelIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'channelId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      channelIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'channelId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      channelIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'channelId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> channelIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'channelId',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> channelIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'channelId',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientAddressB58IsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'clientAddressB58',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientAddressB58IsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'clientAddressB58',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientAddressB58EqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'clientAddressB58',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientAddressB58GreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'clientAddressB58',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientAddressB58LessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'clientAddressB58',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientAddressB58Between(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'clientAddressB58',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientAddressB58StartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'clientAddressB58',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientAddressB58EndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'clientAddressB58',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      clientAddressB58Contains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'clientAddressB58',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      clientAddressB58Matches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'clientAddressB58',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientAddressB58IsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'clientAddressB58',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientAddressB58IsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'clientAddressB58',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientBalanceSatsEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'clientBalanceSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientBalanceSatsGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'clientBalanceSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientBalanceSatsLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'clientBalanceSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientBalanceSatsBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'clientBalanceSats',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientBalanceSatsStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'clientBalanceSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientBalanceSatsEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'clientBalanceSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      clientBalanceSatsContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'clientBalanceSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      clientBalanceSatsMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'clientBalanceSats',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientBalanceSatsIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'clientBalanceSats',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientBalanceSatsIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'clientBalanceSats',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPeerIdEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'clientPeerId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPeerIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'clientPeerId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPeerIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'clientPeerId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPeerIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'clientPeerId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPeerIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'clientPeerId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPeerIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'clientPeerId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      clientPeerIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'clientPeerId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      clientPeerIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'clientPeerId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPeerIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'clientPeerId',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPeerIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'clientPeerId',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPubKeyHexEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'clientPubKeyHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPubKeyHexGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'clientPubKeyHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPubKeyHexLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'clientPubKeyHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPubKeyHexBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'clientPubKeyHex',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPubKeyHexStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'clientPubKeyHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPubKeyHexEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'clientPubKeyHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      clientPubKeyHexContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'clientPubKeyHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      clientPubKeyHexMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'clientPubKeyHex',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPubKeyHexIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'clientPubKeyHex',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> clientPubKeyHexIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'clientPubKeyHex',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> closedAtIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'closedAt',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> closedAtIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'closedAt',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> closedAtEqualTo(DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'closedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> closedAtGreaterThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'closedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> closedAtLessThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'closedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> closedAtBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'closedAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> contextIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'context',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> contextIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'context',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> contextEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'context',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> contextGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'context',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> contextLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'context',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> contextBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'context',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> contextStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'context',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> contextEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'context',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      contextContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'context',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      contextMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'context',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> contextIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'context',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> contextIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'context',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> createdAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'createdAt',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> errorMessageIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'errorMessage',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> errorMessageIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'errorMessage',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> errorMessageEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'errorMessage',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> errorMessageGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'errorMessage',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> errorMessageLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'errorMessage',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> errorMessageBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'errorMessage',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> errorMessageStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'errorMessage',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> errorMessageEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'errorMessage',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      errorMessageContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'errorMessage',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      errorMessageMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'errorMessage',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> errorMessageIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'errorMessage',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> errorMessageIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'errorMessage',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAmountSatsEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'fundingAmountSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAmountSatsGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'fundingAmountSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAmountSatsLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'fundingAmountSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAmountSatsBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'fundingAmountSats',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAmountSatsStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'fundingAmountSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAmountSatsEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'fundingAmountSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      fundingAmountSatsContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'fundingAmountSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      fundingAmountSatsMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'fundingAmountSats',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAmountSatsIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'fundingAmountSats',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAmountSatsIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'fundingAmountSats',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAncestorTxidsElementEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'fundingAncestorTxids',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAncestorTxidsElementGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'fundingAncestorTxids',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAncestorTxidsElementLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'fundingAncestorTxids',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAncestorTxidsElementBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'fundingAncestorTxids',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAncestorTxidsElementStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'fundingAncestorTxids',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAncestorTxidsElementEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'fundingAncestorTxids',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      fundingAncestorTxidsElementContains(String value,
          {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'fundingAncestorTxids',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      fundingAncestorTxidsElementMatches(String pattern,
          {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'fundingAncestorTxids',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAncestorTxidsElementIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'fundingAncestorTxids',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAncestorTxidsElementIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'fundingAncestorTxids',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAncestorTxidsLengthEqualTo(int length) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'fundingAncestorTxids',
        length,
        true,
        length,
        true,
      );
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAncestorTxidsIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'fundingAncestorTxids',
        0,
        true,
        0,
        true,
      );
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAncestorTxidsIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'fundingAncestorTxids',
        0,
        false,
        999999,
        true,
      );
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAncestorTxidsLengthLessThan(
    int length, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'fundingAncestorTxids',
        0,
        true,
        length,
        include,
      );
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAncestorTxidsLengthGreaterThan(
    int length, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'fundingAncestorTxids',
        length,
        include,
        999999,
        true,
      );
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingAncestorTxidsLengthBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.listLength(
        r'fundingAncestorTxids',
        lower,
        includeLower,
        upper,
        includeUpper,
      );
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingOutputIndexIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'fundingOutputIndex',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingOutputIndexIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'fundingOutputIndex',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingOutputIndexEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'fundingOutputIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingOutputIndexGreaterThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'fundingOutputIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingOutputIndexLessThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'fundingOutputIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingOutputIndexBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'fundingOutputIndex',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxHexIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'fundingTxHex',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxHexIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'fundingTxHex',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxHexEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'fundingTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxHexGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'fundingTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxHexLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'fundingTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxHexBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'fundingTxHex',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxHexStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'fundingTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxHexEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'fundingTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      fundingTxHexContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'fundingTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      fundingTxHexMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'fundingTxHex',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxHexIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'fundingTxHex',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxHexIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'fundingTxHex',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxIdIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'fundingTxId',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxIdIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'fundingTxId',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxIdEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'fundingTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxIdGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'fundingTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxIdLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'fundingTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxIdBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'fundingTxId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'fundingTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'fundingTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      fundingTxIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'fundingTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      fundingTxIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'fundingTxId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'fundingTxId',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> fundingTxIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'fundingTxId',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> hasFundingMerkleProofEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'hasFundingMerkleProof',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxHexIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'latestPaymentTxHex',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxHexIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'latestPaymentTxHex',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxHexEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'latestPaymentTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxHexGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'latestPaymentTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxHexLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'latestPaymentTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxHexBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'latestPaymentTxHex',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxHexStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'latestPaymentTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxHexEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'latestPaymentTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      latestPaymentTxHexContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'latestPaymentTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      latestPaymentTxHexMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'latestPaymentTxHex',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxHexIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'latestPaymentTxHex',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxHexIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'latestPaymentTxHex',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxIdIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'latestPaymentTxId',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxIdIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'latestPaymentTxId',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxIdEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'latestPaymentTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxIdGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'latestPaymentTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxIdLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'latestPaymentTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxIdBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'latestPaymentTxId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'latestPaymentTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'latestPaymentTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      latestPaymentTxIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'latestPaymentTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      latestPaymentTxIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'latestPaymentTxId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'latestPaymentTxId',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestPaymentTxIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'latestPaymentTxId',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestSequenceNumberEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'latestSequenceNumber',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestSequenceNumberGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'latestSequenceNumber',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestSequenceNumberLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'latestSequenceNumber',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> latestSequenceNumberBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'latestSequenceNumber',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> lockTimeUnixEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'lockTimeUnix',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> lockTimeUnixGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'lockTimeUnix',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> lockTimeUnixLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'lockTimeUnix',
        value: value,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> lockTimeUnixBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'lockTimeUnix',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundClientSigHexIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'refundClientSigHex',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundClientSigHexIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'refundClientSigHex',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundClientSigHexEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'refundClientSigHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundClientSigHexGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'refundClientSigHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundClientSigHexLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'refundClientSigHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundClientSigHexBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'refundClientSigHex',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundClientSigHexStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'refundClientSigHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundClientSigHexEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'refundClientSigHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      refundClientSigHexContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'refundClientSigHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      refundClientSigHexMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'refundClientSigHex',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundClientSigHexIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'refundClientSigHex',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundClientSigHexIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'refundClientSigHex',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundServerSigHexIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'refundServerSigHex',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundServerSigHexIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'refundServerSigHex',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundServerSigHexEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'refundServerSigHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundServerSigHexGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'refundServerSigHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundServerSigHexLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'refundServerSigHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundServerSigHexBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'refundServerSigHex',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundServerSigHexStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'refundServerSigHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundServerSigHexEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'refundServerSigHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      refundServerSigHexContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'refundServerSigHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      refundServerSigHexMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'refundServerSigHex',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundServerSigHexIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'refundServerSigHex',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundServerSigHexIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'refundServerSigHex',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundTxHexIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'refundTxHex',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundTxHexIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'refundTxHex',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundTxHexEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'refundTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundTxHexGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'refundTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundTxHexLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'refundTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundTxHexBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'refundTxHex',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundTxHexStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'refundTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundTxHexEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'refundTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      refundTxHexContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'refundTxHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      refundTxHexMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'refundTxHex',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundTxHexIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'refundTxHex',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> refundTxHexIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'refundTxHex',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> roleEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'role',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> roleGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'role',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> roleLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'role',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> roleBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'role',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> roleStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'role',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> roleEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'role',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      roleContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'role',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      roleMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'role',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> roleIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'role',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> roleIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'role',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverAddressB58IsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'serverAddressB58',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverAddressB58IsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'serverAddressB58',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverAddressB58EqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'serverAddressB58',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverAddressB58GreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'serverAddressB58',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverAddressB58LessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'serverAddressB58',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverAddressB58Between(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'serverAddressB58',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverAddressB58StartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'serverAddressB58',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverAddressB58EndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'serverAddressB58',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      serverAddressB58Contains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'serverAddressB58',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      serverAddressB58Matches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'serverAddressB58',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverAddressB58IsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'serverAddressB58',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverAddressB58IsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'serverAddressB58',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverBalanceSatsEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'serverBalanceSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverBalanceSatsGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'serverBalanceSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverBalanceSatsLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'serverBalanceSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverBalanceSatsBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'serverBalanceSats',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverBalanceSatsStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'serverBalanceSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverBalanceSatsEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'serverBalanceSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      serverBalanceSatsContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'serverBalanceSats',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      serverBalanceSatsMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'serverBalanceSats',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverBalanceSatsIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'serverBalanceSats',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverBalanceSatsIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'serverBalanceSats',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPeerIdEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'serverPeerId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPeerIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'serverPeerId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPeerIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'serverPeerId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPeerIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'serverPeerId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPeerIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'serverPeerId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPeerIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'serverPeerId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      serverPeerIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'serverPeerId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      serverPeerIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'serverPeerId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPeerIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'serverPeerId',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPeerIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'serverPeerId',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPubKeyHexEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'serverPubKeyHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPubKeyHexGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'serverPubKeyHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPubKeyHexLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'serverPubKeyHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPubKeyHexBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'serverPubKeyHex',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPubKeyHexStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'serverPubKeyHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPubKeyHexEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'serverPubKeyHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      serverPubKeyHexContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'serverPubKeyHex',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      serverPubKeyHexMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'serverPubKeyHex',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPubKeyHexIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'serverPubKeyHex',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> serverPubKeyHexIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'serverPubKeyHex',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> settlementTxIdIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'settlementTxId',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> settlementTxIdIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'settlementTxId',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> settlementTxIdEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'settlementTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> settlementTxIdGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'settlementTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> settlementTxIdLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'settlementTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> settlementTxIdBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'settlementTxId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> settlementTxIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'settlementTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> settlementTxIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'settlementTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      settlementTxIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'settlementTxId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      settlementTxIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'settlementTxId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> settlementTxIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'settlementTxId',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> settlementTxIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'settlementTxId',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> stateEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'state',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> stateGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'state',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> stateLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'state',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> stateBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'state',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> stateStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'state',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> stateEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'state',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      stateContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'state',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
          QAfterFilterCondition>
      stateMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'state',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> stateIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'state',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> stateIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'state',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
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

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> walletIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'walletId',
        value: '',
      ));
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity,
      QAfterFilterCondition> walletIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'walletId',
        value: '',
      ));
    });
  }
}

extension PaymentChannelEntityQueryObject on QueryBuilder<PaymentChannelEntity,
    PaymentChannelEntity, QFilterCondition> {}

extension PaymentChannelEntityQueryLinks on QueryBuilder<PaymentChannelEntity,
    PaymentChannelEntity, QFilterCondition> {}

extension PaymentChannelEntityQuerySortBy
    on QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QSortBy> {
  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByChannelId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'channelId', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByChannelIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'channelId', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByClientAddressB58() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientAddressB58', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByClientAddressB58Desc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientAddressB58', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByClientBalanceSats() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientBalanceSats', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByClientBalanceSatsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientBalanceSats', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByClientPeerId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientPeerId', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByClientPeerIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientPeerId', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByClientPubKeyHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientPubKeyHex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByClientPubKeyHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientPubKeyHex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByClosedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'closedAt', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByClosedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'closedAt', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByContext() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'context', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByContextDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'context', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByErrorMessage() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'errorMessage', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByErrorMessageDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'errorMessage', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByFundingAmountSats() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingAmountSats', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByFundingAmountSatsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingAmountSats', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByFundingOutputIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingOutputIndex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByFundingOutputIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingOutputIndex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByFundingTxHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingTxHex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByFundingTxHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingTxHex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByFundingTxId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingTxId', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByFundingTxIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingTxId', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByHasFundingMerkleProof() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasFundingMerkleProof', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByHasFundingMerkleProofDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasFundingMerkleProof', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByLatestPaymentTxHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'latestPaymentTxHex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByLatestPaymentTxHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'latestPaymentTxHex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByLatestPaymentTxId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'latestPaymentTxId', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByLatestPaymentTxIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'latestPaymentTxId', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByLatestSequenceNumber() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'latestSequenceNumber', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByLatestSequenceNumberDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'latestSequenceNumber', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByLockTimeUnix() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lockTimeUnix', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByLockTimeUnixDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lockTimeUnix', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByRefundClientSigHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'refundClientSigHex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByRefundClientSigHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'refundClientSigHex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByRefundServerSigHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'refundServerSigHex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByRefundServerSigHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'refundServerSigHex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByRefundTxHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'refundTxHex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByRefundTxHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'refundTxHex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByRole() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'role', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByRoleDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'role', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByServerAddressB58() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverAddressB58', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByServerAddressB58Desc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverAddressB58', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByServerBalanceSats() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverBalanceSats', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByServerBalanceSatsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverBalanceSats', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByServerPeerId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverPeerId', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByServerPeerIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverPeerId', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByServerPubKeyHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverPubKeyHex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByServerPubKeyHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverPubKeyHex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortBySettlementTxId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'settlementTxId', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortBySettlementTxIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'settlementTxId', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByState() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'state', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByStateDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'state', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      sortByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }
}

extension PaymentChannelEntityQuerySortThenBy
    on QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QSortThenBy> {
  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByChannelId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'channelId', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByChannelIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'channelId', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByClientAddressB58() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientAddressB58', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByClientAddressB58Desc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientAddressB58', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByClientBalanceSats() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientBalanceSats', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByClientBalanceSatsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientBalanceSats', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByClientPeerId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientPeerId', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByClientPeerIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientPeerId', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByClientPubKeyHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientPubKeyHex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByClientPubKeyHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'clientPubKeyHex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByClosedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'closedAt', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByClosedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'closedAt', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByContext() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'context', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByContextDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'context', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByCreatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'createdAt', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByErrorMessage() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'errorMessage', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByErrorMessageDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'errorMessage', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByFundingAmountSats() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingAmountSats', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByFundingAmountSatsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingAmountSats', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByFundingOutputIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingOutputIndex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByFundingOutputIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingOutputIndex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByFundingTxHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingTxHex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByFundingTxHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingTxHex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByFundingTxId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingTxId', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByFundingTxIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'fundingTxId', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByHasFundingMerkleProof() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasFundingMerkleProof', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByHasFundingMerkleProofDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hasFundingMerkleProof', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByLatestPaymentTxHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'latestPaymentTxHex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByLatestPaymentTxHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'latestPaymentTxHex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByLatestPaymentTxId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'latestPaymentTxId', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByLatestPaymentTxIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'latestPaymentTxId', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByLatestSequenceNumber() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'latestSequenceNumber', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByLatestSequenceNumberDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'latestSequenceNumber', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByLockTimeUnix() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lockTimeUnix', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByLockTimeUnixDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lockTimeUnix', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByRefundClientSigHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'refundClientSigHex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByRefundClientSigHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'refundClientSigHex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByRefundServerSigHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'refundServerSigHex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByRefundServerSigHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'refundServerSigHex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByRefundTxHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'refundTxHex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByRefundTxHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'refundTxHex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByRole() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'role', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByRoleDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'role', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByServerAddressB58() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverAddressB58', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByServerAddressB58Desc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverAddressB58', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByServerBalanceSats() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverBalanceSats', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByServerBalanceSatsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverBalanceSats', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByServerPeerId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverPeerId', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByServerPeerIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverPeerId', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByServerPubKeyHex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverPubKeyHex', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByServerPubKeyHexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverPubKeyHex', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenBySettlementTxId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'settlementTxId', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenBySettlementTxIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'settlementTxId', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByState() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'state', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByStateDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'state', Sort.desc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByWalletId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.asc);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QAfterSortBy>
      thenByWalletIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'walletId', Sort.desc);
    });
  }
}

extension PaymentChannelEntityQueryWhereDistinct
    on QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct> {
  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByChannelId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'channelId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByClientAddressB58({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'clientAddressB58',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByClientBalanceSats({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'clientBalanceSats',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByClientPeerId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'clientPeerId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByClientPubKeyHex({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'clientPubKeyHex',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByClosedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'closedAt');
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByContext({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'context', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByCreatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'createdAt');
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByErrorMessage({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'errorMessage', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByFundingAmountSats({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'fundingAmountSats',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByFundingAncestorTxids() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'fundingAncestorTxids');
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByFundingOutputIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'fundingOutputIndex');
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByFundingTxHex({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'fundingTxHex', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByFundingTxId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'fundingTxId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByHasFundingMerkleProof() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'hasFundingMerkleProof');
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByLatestPaymentTxHex({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'latestPaymentTxHex',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByLatestPaymentTxId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'latestPaymentTxId',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByLatestSequenceNumber() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'latestSequenceNumber');
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByLockTimeUnix() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'lockTimeUnix');
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByRefundClientSigHex({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'refundClientSigHex',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByRefundServerSigHex({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'refundServerSigHex',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByRefundTxHex({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'refundTxHex', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByRole({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'role', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByServerAddressB58({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'serverAddressB58',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByServerBalanceSats({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'serverBalanceSats',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByServerPeerId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'serverPeerId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByServerPubKeyHex({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'serverPubKeyHex',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctBySettlementTxId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'settlementTxId',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByState({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'state', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<PaymentChannelEntity, PaymentChannelEntity, QDistinct>
      distinctByWalletId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'walletId', caseSensitive: caseSensitive);
    });
  }
}

extension PaymentChannelEntityQueryProperty on QueryBuilder<
    PaymentChannelEntity, PaymentChannelEntity, QQueryProperty> {
  QueryBuilder<PaymentChannelEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<PaymentChannelEntity, String, QQueryOperations>
      channelIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'channelId');
    });
  }

  QueryBuilder<PaymentChannelEntity, String?, QQueryOperations>
      clientAddressB58Property() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'clientAddressB58');
    });
  }

  QueryBuilder<PaymentChannelEntity, String, QQueryOperations>
      clientBalanceSatsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'clientBalanceSats');
    });
  }

  QueryBuilder<PaymentChannelEntity, String, QQueryOperations>
      clientPeerIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'clientPeerId');
    });
  }

  QueryBuilder<PaymentChannelEntity, String, QQueryOperations>
      clientPubKeyHexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'clientPubKeyHex');
    });
  }

  QueryBuilder<PaymentChannelEntity, DateTime?, QQueryOperations>
      closedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'closedAt');
    });
  }

  QueryBuilder<PaymentChannelEntity, String?, QQueryOperations>
      contextProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'context');
    });
  }

  QueryBuilder<PaymentChannelEntity, DateTime, QQueryOperations>
      createdAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'createdAt');
    });
  }

  QueryBuilder<PaymentChannelEntity, String?, QQueryOperations>
      errorMessageProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'errorMessage');
    });
  }

  QueryBuilder<PaymentChannelEntity, String, QQueryOperations>
      fundingAmountSatsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'fundingAmountSats');
    });
  }

  QueryBuilder<PaymentChannelEntity, List<String>, QQueryOperations>
      fundingAncestorTxidsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'fundingAncestorTxids');
    });
  }

  QueryBuilder<PaymentChannelEntity, int?, QQueryOperations>
      fundingOutputIndexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'fundingOutputIndex');
    });
  }

  QueryBuilder<PaymentChannelEntity, String?, QQueryOperations>
      fundingTxHexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'fundingTxHex');
    });
  }

  QueryBuilder<PaymentChannelEntity, String?, QQueryOperations>
      fundingTxIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'fundingTxId');
    });
  }

  QueryBuilder<PaymentChannelEntity, bool, QQueryOperations>
      hasFundingMerkleProofProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'hasFundingMerkleProof');
    });
  }

  QueryBuilder<PaymentChannelEntity, String?, QQueryOperations>
      latestPaymentTxHexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'latestPaymentTxHex');
    });
  }

  QueryBuilder<PaymentChannelEntity, String?, QQueryOperations>
      latestPaymentTxIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'latestPaymentTxId');
    });
  }

  QueryBuilder<PaymentChannelEntity, int, QQueryOperations>
      latestSequenceNumberProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'latestSequenceNumber');
    });
  }

  QueryBuilder<PaymentChannelEntity, int, QQueryOperations>
      lockTimeUnixProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'lockTimeUnix');
    });
  }

  QueryBuilder<PaymentChannelEntity, String?, QQueryOperations>
      refundClientSigHexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'refundClientSigHex');
    });
  }

  QueryBuilder<PaymentChannelEntity, String?, QQueryOperations>
      refundServerSigHexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'refundServerSigHex');
    });
  }

  QueryBuilder<PaymentChannelEntity, String?, QQueryOperations>
      refundTxHexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'refundTxHex');
    });
  }

  QueryBuilder<PaymentChannelEntity, String, QQueryOperations> roleProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'role');
    });
  }

  QueryBuilder<PaymentChannelEntity, String?, QQueryOperations>
      serverAddressB58Property() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'serverAddressB58');
    });
  }

  QueryBuilder<PaymentChannelEntity, String, QQueryOperations>
      serverBalanceSatsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'serverBalanceSats');
    });
  }

  QueryBuilder<PaymentChannelEntity, String, QQueryOperations>
      serverPeerIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'serverPeerId');
    });
  }

  QueryBuilder<PaymentChannelEntity, String, QQueryOperations>
      serverPubKeyHexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'serverPubKeyHex');
    });
  }

  QueryBuilder<PaymentChannelEntity, String?, QQueryOperations>
      settlementTxIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'settlementTxId');
    });
  }

  QueryBuilder<PaymentChannelEntity, String, QQueryOperations> stateProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'state');
    });
  }

  QueryBuilder<PaymentChannelEntity, String, QQueryOperations>
      walletIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'walletId');
    });
  }
}
