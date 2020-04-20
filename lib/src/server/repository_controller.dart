import 'dart:async';

import 'package:json_api/document.dart';
import 'package:json_api/routing.dart';
import 'package:json_api/src/server/collection.dart';
import 'package:json_api/src/server/controller.dart';
import 'package:json_api/src/server/pagination.dart';
import 'package:json_api/src/server/repository.dart';
import 'package:json_api/src/server/request.dart';
import 'package:json_api/src/server/response.dart';

/// An opinionated implementation of [Controller]. Translates JSON:API
/// requests to [Repository] methods calls.
class RepositoryController implements Controller {
  RepositoryController(this._repo, {Pagination pagination})
      : _pagination = pagination ?? NoPagination();

  final Repository _repo;
  final Pagination _pagination;

  @override
  Future<Response> addToRelationship(
          Request<RelationshipTarget> request, List<Identifier> identifiers) =>
      _do(() async {
        final original =
            await _repo.get(request.target.type, request.target.id);
        if (!original.toMany.containsKey(request.target.relationship)) {
          return ErrorResponse(404, [
            ErrorObject(
                status: '404',
                title: 'Relationship not found',
                detail:
                    "There is no to-many relationship '${request.target.relationship}' in this resource")
          ]);
        }
        final updated = await _repo.update(
            request.target.type,
            request.target.id,
            Resource(request.target.type, request.target.id, toMany: {
              request.target.relationship: {
                ...original.toMany[request.target.relationship],
                ...identifiers
              }.toList()
            }));
        return ToManyResponse(
            request, updated.toMany[request.target.relationship]);
      });

  @override
  Future<Response> createResource(
          Request<CollectionTarget> request, Resource resource) =>
      _do(() async {
        final modified = await _repo.create(request.target.type, resource);
        if (modified == null) {
          return NoContentResponse();
        }
        return CreatedResourceResponse(request, modified);
      });

  @override
  Future<Response> deleteFromRelationship(
          Request<RelationshipTarget> request, List<Identifier> identifiers) =>
      _do(() async {
        final original =
            await _repo.get(request.target.type, request.target.id);
        final updated = await _repo.update(
            request.target.type,
            request.target.id,
            Resource(request.target.type, request.target.id, toMany: {
              request.target.relationship: ({
                ...original.toMany[request.target.relationship]
              }..removeAll(identifiers))
                  .toList()
            }));
        return ToManyResponse(
            request, updated.toMany[request.target.relationship]);
      });

  @override
  Future<Response> deleteResource(Request<ResourceTarget> request) =>
      _do(() async {
        await _repo.delete(request.target.type, request.target.id);
        return NoContentResponse();
      });

  @override
  Future<Response> fetchCollection(Request<CollectionTarget> request) =>
      _do(() async {
        final limit = _pagination.limit(request.page);
        final offset = _pagination.offset(request.page);

        final collection = await _repo.getCollection(request.target.type,
            sort: request.sort.toList(), limit: limit, offset: offset);

        final resources = <Resource>[];
        for (final resource in collection.elements) {
          for (final path in request.include) {
            resources.addAll(await _getRelated(resource, path.split('.')));
          }
        }
        return PrimaryCollectionResponse(request, collection,
            include: request.isCompound ? resources : null);
      });

  @override
  Future<Response> fetchRelated(Request<RelatedTarget> request) =>
      _do(() async {
        final resource =
            await _repo.get(request.target.type, request.target.id);
        if (resource.toOne.containsKey(request.target.relationship)) {
          final i = resource.toOne[request.target.relationship];
          return RelatedResourceResponse(
              request, await _repo.get(i.type, i.id));
        }
        if (resource.toMany.containsKey(request.target.relationship)) {
          final related = <Resource>[];
          for (final identifier
              in resource.toMany[request.target.relationship]) {
            related.add(await _repo.get(identifier.type, identifier.id));
          }
          return RelatedCollectionResponse(request, Collection(related));
        }
        return ErrorResponse(
            404, _relationshipNotFound(request.target.relationship));
      });

  @override
  Future<Response> fetchRelationship(Request<RelationshipTarget> request) =>
      _do(() async {
        final resource =
            await _repo.get(request.target.type, request.target.id);
        if (resource.toOne.containsKey(request.target.relationship)) {
          return ToOneResponse(
              request, resource.toOne[request.target.relationship]);
        }
        if (resource.toMany.containsKey(request.target.relationship)) {
          return ToManyResponse(
              request, resource.toMany[request.target.relationship]);
        }
        return ErrorResponse(
            404, _relationshipNotFound(request.target.relationship));
      });

  @override
  Future<Response> fetchResource(Request<ResourceTarget> request) =>
      _do(() async {
        final resource =
            await _repo.get(request.target.type, request.target.id);
        final resources = <Resource>[];
        for (final path in request.include) {
          resources.addAll(await _getRelated(resource, path.split('.')));
        }
        return PrimaryResourceResponse(request, resource,
            include: request.isCompound ? resources : null);
      });

  @override
  Future<Response> replaceToMany(
          Request<RelationshipTarget> request, List<Identifier> identifiers) =>
      _do(() async {
        await _repo.update(
            request.target.type,
            request.target.id,
            Resource(request.target.type, request.target.id,
                toMany: {request.target.relationship: identifiers}));
        return NoContentResponse();
      });

  @override
  Future<Response> updateResource(
          Request<ResourceTarget> request, Resource resource) =>
      _do(() async {
        final modified = await _repo.update(
            request.target.type, request.target.id, resource);
        if (modified == null) {
          return NoContentResponse();
        }
        return PrimaryResourceResponse(request, modified, include: null);
      });

  @override
  Future<Response> replaceToOne(
          Request<RelationshipTarget> request, Identifier identifier) =>
      _do(() async {
        await _repo.update(
            request.target.type,
            request.target.id,
            Resource(request.target.type, request.target.id,
                toOne: {request.target.relationship: identifier}));
        return NoContentResponse();
      });

  Future<Iterable<Resource>> _getRelated(
    Resource resource,
    Iterable<String> path,
  ) async {
    if (path.isEmpty) return [];
    final resources = <Resource>[];
    final ids = <Identifier>[];

    if (resource.toOne.containsKey(path.first)) {
      ids.add(resource.toOne[path.first]);
    } else if (resource.toMany.containsKey(path.first)) {
      ids.addAll(resource.toMany[path.first]);
    }
    for (final id in ids) {
      final r = await _repo.get(id.type, id.id);
      if (path.length > 1) {
        resources.addAll(await _getRelated(r, path.skip(1)));
      } else {
        resources.add(r);
      }
    }
    return _unique(resources);
  }

  Iterable<Resource> _unique(Iterable<Resource> included) =>
      Map<String, Resource>.fromIterable(included,
          key: (_) => '${_.type}:${_.id}').values;

  Future<Response> _do(Future<Response> Function() action) async {
    try {
      return await action();
    } on UnsupportedOperation catch (e) {
      return ErrorResponse(403, [
        ErrorObject(
            status: '403', title: 'Unsupported operation', detail: e.message)
      ]);
    } on CollectionNotFound catch (e) {
      return ErrorResponse(404, [
        ErrorObject(
            status: '404', title: 'Collection not found', detail: e.message)
      ]);
    } on ResourceNotFound catch (e) {
      return ErrorResponse(404, [
        ErrorObject(
            status: '404', title: 'Resource not found', detail: e.message)
      ]);
    } on InvalidType catch (e) {
      return ErrorResponse(409, [
        ErrorObject(
            status: '409', title: 'Invalid resource type', detail: e.message)
      ]);
    } on ResourceExists catch (e) {
      return ErrorResponse(409, [
        ErrorObject(status: '409', title: 'Resource exists', detail: e.message)
      ]);
    }
  }

  List<ErrorObject> _relationshipNotFound(String relationship) => [
        ErrorObject(
            status: '404',
            title: 'Relationship not found',
            detail:
                "Relationship '$relationship' does not exist in this resource")
      ];
}