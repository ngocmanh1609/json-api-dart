import 'dart:async';

import 'package:json_api/document.dart';
import 'package:json_api/src/server/repository.dart';

typedef IdGenerator = String Function();
typedef TypeAttributionCriteria = bool Function(String collection, String type);

/// An in-memory implementation of [Repository]
class InMemoryRepository implements Repository {
  final Map<String, Map<String, Resource>> _collections;
  final IdGenerator _nextId;

  @override
  FutureOr<Resource> create(String collection, Resource resource) async {
    if (!_collections.containsKey(collection)) {
      throw CollectionNotFound("Collection '$collection' does not exist");
    }
    if (collection != resource.type) {
      throw _invalidType(resource, collection);
    }
    for (final relationship in resource.toOne.values
        .followedBy(resource.toMany.values.expand((_) => _))) {
      await get(relationship.type, relationship.id);
    }
    if (resource.id == null) {
      if (_nextId == null) {
        throw UnsupportedOperation('Id generation is not supported');
      }
      final id = _nextId();
      final created = resource.replace(id: id);
      _collections[collection][created.id] = created;
      return created;
    }
    if (_collections[collection].containsKey(resource.id)) {
      throw ResourceExists('Resource with this type and id already exists');
    }
    _collections[collection][resource.id] = resource;
    return null;
  }

  @override
  FutureOr<Resource> get(String collection, String id) async {
    if (_collections.containsKey(collection)) {
      final resource = _collections[collection][id];
      if (resource == null) {
        throw ResourceNotFound(
            "Resource '$id' does not exist in '$collection'");
      }
      return resource;
    }
    throw CollectionNotFound("Collection '$collection' does not exist");
  }

  @override
  FutureOr<Resource> update(
      String collection, String id, Resource resource) async {
    if (collection != resource.type) {
      throw _invalidType(resource, collection);
    }
    final original = await get(collection, id);
    if (resource.attributes.isEmpty &&
        resource.toOne.isEmpty &&
        resource.toMany.isEmpty &&
        resource.id == id) {
      return null;
    }
    final updated = Resource(
      original.type,
      original.id,
      attributes: {...original.attributes}..addAll(resource.attributes),
      toOne: {...original.toOne}..addAll(resource.toOne),
      toMany: {...original.toMany}..addAll(resource.toMany),
    );
    _collections[collection][id] = updated;
    return updated;
  }

  @override
  FutureOr<void> delete(String type, String id) async {
    await get(type, id);
    _collections[type].remove(id);
    return null;
  }

  @override
  FutureOr<Collection<Resource>> getCollection(String collection) async {
    if (_collections.containsKey(collection)) {
      return Collection(
          _collections[collection].values, _collections[collection].length);
    }
    throw CollectionNotFound("Collection '$collection' does not exist");
  }

  InvalidType _invalidType(Resource resource, String collection) {
    return InvalidType(
        "Type '${resource.type}' does not belong in '$collection'");
  }

  InMemoryRepository(this._collections, {IdGenerator nextId})
      : _nextId = nextId;
}