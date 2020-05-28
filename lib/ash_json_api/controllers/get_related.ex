defmodule AshJsonApi.Controllers.GetRelated do
  alias AshJsonApi.Controllers.{Helpers, Response}
  alias AshJsonApi.Request

  def init(options) do
    # initialize options
    options
  end

  def call(conn, options) do
    action = options[:action]
    api = options[:api]
    route = options[:route]
    relationship = Ash.relationship(options[:resource], route.relationship)
    resource = relationship.destination

    paginate? = relationship.cardinality == :many

    conn
    |> Request.from(resource, action, api, route)
    |> Helpers.fetch_record_from_path(options[:resource])
    |> Helpers.fetch_related(paginate?)
    |> Helpers.fetch_includes()
    |> Helpers.render_or_render_errors(conn, fn request ->
      case relationship.cardinality do
        :one ->
          Response.render_one(
            conn,
            request,
            200,
            List.first(request.assigns.result),
            request.assigns.includes
          )

        :many ->
          Response.render_many(
            conn,
            request,
            200,
            request.assigns.result,
            request.assigns.includes,
            false
          )
      end
    end)
  end
end
