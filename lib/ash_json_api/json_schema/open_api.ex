if Code.ensure_loaded?(OpenApiSpex) do
  defmodule AshJsonApi.OpenApi do
    @moduledoc """
    Provides functions for generating schemas and operations for OpenApi definitions.

    Add `open_api_spex` to your `mix.exs` deps for the required struct definitions.

    ## Example

        defmodule MyApp.OpenApi do
          alias OpenApiSpex.{OpenApi, Info, Server, Components}

          def spec do
            %OpenApi{
              info: %Info{
                title: "MyApp JSON API",
                version: "1.1"
              },
              servers: [
                Server.from_endpoint(MyAppWeb.Endpoint)
              ],
              paths: AshJsonApi.OpenApi.paths(MyApp.Api),
              tags: AshJsonApi.OpenApi.tags(MyApp.Api),
              components: %Components{
                responses: AshJsonApi.OpenApi.responses(),
                schemas: AshJsonApi.OpenApi.schemas(MyApp.Api)
              }
            }
          end
        end
    """
    alias Ash.Query.Aggregate
    alias AshJsonApi.Resource.Route
    alias Ash.Resource.{Actions, Relationships}

    alias OpenApiSpex.{
      MediaType,
      Operation,
      Parameter,
      PathItem,
      Paths,
      Reference,
      RequestBody,
      Response,
      Schema,
      Tag
    }

    @dialyzer {:nowarn_function, {:action_description, 3}}
    @dialyzer {:nowarn_function, {:relationship_resource_identifiers, 1}}
    @dialyzer {:nowarn_function, {:resource_object_schema, 1}}

    @doc """
    Common responses to include in the API Spec.
    """
    @spec responses() :: OpenApiSpex.Components.responses_map()
    def responses do
      %{
        "errors" => %Response{
          description: "General Error",
          content: %{
            "application/vnd.api+json" => %MediaType{
              schema: %Reference{"$ref": "#/components/schemas/errors"}
            }
          }
        }
      }
    end

    @doc """
    Resource schemas to include in the API spec.
    """
    @spec schemas(domain :: module | [module]) :: %{String.t() => Schema.t()}
    def schemas(domains) when is_list(domains) do
      domains
      |> Enum.reduce(base_definitions(), fn domain, definitions ->
        domain
        |> resources
        |> Enum.flat_map(fn resource ->
          [
            {AshJsonApi.Resource.Info.type(resource), resource_object_schema(resource)}
          ] ++
            resource_filter_schemas(domains, resource)
        end)
        |> Enum.into(definitions)
      end)
    end

    def schemas(domain) do
      schemas(List.wrap(domain))
    end

    defp define_filter?(domains, resource) do
      if AshJsonApi.Resource.Info.derive_filter?(resource) do
        resource
        |> AshJsonApi.Resource.Info.routes(domains)
        |> Enum.any?(fn route ->
          route.type == :index && read_action?(resource, route) && route.derive_filter?
        end)
      else
        false
      end
    end

    defp read_action?(resource, route) do
      action = Ash.Resource.Info.action(resource, route.action)

      action && action.type == :read
    end

    defp resource_filter_schemas(domains, resource) do
      if define_filter?(domains, resource) do
        [
          {
            "#{AshJsonApi.Resource.Info.type(resource)}-filter",
            %Schema{
              type: :object,
              properties: resource_filter_fields(resource),
              additionalProperties: false,
              description: "Filters the query to results matching the given filter object"
            }
          }
        ] ++ filter_field_types(resource)
      else
        []
      end
    end

    @spec base_definitions() :: %{String.t() => Schema.t()}
    defp base_definitions do
      %{
        "links" => %Schema{
          type: :object,
          additionalProperties: %Reference{"$ref": "#/components/schemas/link"}
        },
        "link" => %Schema{
          description:
            "A link MUST be represented as either: a string containing the link's URL or a link object.",
          type: :string
        },
        "errors" => %Schema{
          type: :array,
          items: %Reference{
            "$ref": "#/components/schemas/error"
          },
          uniqueItems: true
        },
        "error" => %Schema{
          type: :object,
          properties: %{
            id: %Schema{
              description: "A unique identifier for this particular occurrence of the problem.",
              type: :string
            },
            links: %Reference{
              "$ref": "#/components/schemas/links"
            },
            status: %Schema{
              description:
                "The HTTP status code applicable to this problem, expressed as a string value.",
              type: :string
            },
            code: %Schema{
              description: "An application-specific error code, expressed as a string value.",
              type: :string
            },
            title: %Schema{
              description:
                "A short, human-readable summary of the problem. It SHOULD NOT change from occurrence to occurrence of the problem, except for purposes of localization.",
              type: :string
            },
            detail: %Schema{
              description:
                "A human-readable explanation specific to this occurrence of the problem.",
              type: :string
            },
            source: %Schema{
              type: :object,
              properties: %{
                pointer: %Schema{
                  description:
                    "A JSON Pointer [RFC6901] to the associated entity in the request document [e.g. \"/data\" for a primary data object, or \"/data/attributes/title\" for a specific attribute].",
                  type: :string
                },
                parameter: %Schema{
                  description: "A string indicating which query parameter caused the error.",
                  type: :string
                }
              }
            }
          },
          additionalProperties: false
        }
      }
    end

    defp resources(domain) do
      domain
      |> Ash.Domain.Info.resources()
      |> Enum.filter(&AshJsonApi.Resource.Info.type(&1))
    end

    defp resource_object_schema(resource, fields \\ nil) do
      %Schema{
        description:
          Ash.Resource.Info.description(resource) ||
            "A \"Resource object\" representing a #{AshJsonApi.Resource.Info.type(resource)}",
        type: :object,
        required: [:type, :id],
        properties: %{
          type: %Schema{type: :string},
          id: %{type: :string},
          attributes: attributes(resource, fields),
          relationships: relationships(resource)
        },
        additionalProperties: false
      }
    end

    @spec attributes(resource :: Ash.Resource.t(), fields :: nil | list(atom)) :: Schema.t()
    defp attributes(resource, fields) do
      fields =
        fields || AshJsonApi.Resource.Info.default_fields(resource) ||
          Enum.map(Ash.Resource.Info.public_attributes(resource), & &1.name)

      %Schema{
        description: "An attributes object for a #{AshJsonApi.Resource.Info.type(resource)}",
        type: :object,
        properties: resource_attributes(resource, fields),
        required: required_attributes(resource),
        additionalProperties: false
      }
    end

    defp required_attributes(resource) do
      resource
      |> Ash.Resource.Info.public_attributes()
      |> Enum.reject(&(&1.allow_nil? || AshJsonApi.Resource.only_primary_key?(resource, &1.name)))
      |> Enum.map(&to_string(&1.name))
    end

    @spec resource_attributes(resource :: module, fields :: nil | list(atom)) :: %{
            atom => Schema.t()
          }
    defp resource_attributes(resource, fields \\ nil) do
      resource
      |> Ash.Resource.Info.public_attributes()
      |> Enum.concat(Ash.Resource.Info.public_calculations(resource))
      |> Enum.concat(
        Ash.Resource.Info.public_aggregates(resource)
        |> AshJsonApi.JsonSchema.set_aggregate_constraints(resource)
      )
      |> Enum.map(fn
        %Ash.Resource.Aggregate{} = agg ->
          field =
            if agg.field do
              related = Ash.Resource.Info.related(resource, agg.relationship_path)
              Ash.Resource.Info.field(related, agg.field)
            end

          field_type =
            if field do
              field.type
            end

          field_constraints =
            if field do
              field.constraints
            end

          {:ok, type, constraints} =
            Aggregate.kind_to_type(agg.kind, field_type, field_constraints)

          type = Ash.Type.get_type(type)

          allow_nil? =
            is_nil(Ash.Query.Aggregate.default_value(agg.kind))

          %{
            name: agg.name,
            description: agg.description,
            type: type,
            constraints: constraints,
            allow_nil?: allow_nil?
          }

        other ->
          other
      end)
      |> Enum.reject(&AshJsonApi.Resource.only_primary_key?(resource, &1.name))
      |> Map.new(fn attr ->
        {attr.name,
         resource_attribute_type(attr)
         |> with_attribute_description(attr)
         |> with_attribute_nullability(attr)
         |> with_comment_on_included(attr, fields)}
      end)
    end

    defp with_comment_on_included(schema, attr, fields) do
      new_description =
        if is_nil(fields) || attr.name in fields do
          case schema.description do
            nil ->
              "Field included by default."

            description ->
              if String.ends_with?(description, ["!", "."]) do
                description <> " Field included by default."
              else
                description <> ". Field included by default."
              end
          end
        else
          schema.description
        end

      %Schema{schema | description: new_description}
    end

    defp with_attribute_nullability(%Schema{type: nil} = schema, _), do: schema

    defp with_attribute_nullability(schema, attr) do
      if attr.allow_nil? do
        %Schema{
          anyOf: [%{schema | description: nil}, %Schema{type: :null}],
          description: schema.description
        }
      else
        schema
      end
    end

    @spec resource_write_attribute_type(term(), action_type :: atom) :: Schema.t()
    defp resource_write_attribute_type(%{type: {:array, type}} = attr, action_type) do
      %Schema{
        type: :array,
        items:
          resource_write_attribute_type(
            %{
              attr
              | type: type,
                constraints: attr.constraints[:items] || []
            },
            action_type
          )
      }
    end

    defp resource_write_attribute_type(
           %{type: Ash.Type.Union, constraints: constraints} = attr,
           action_type
         ) do
      subtypes =
        Enum.map(constraints[:types], fn {_name, config} ->
          fake_attr = %{attr | type: config[:type], constraints: config[:constraints]}

          resource_write_attribute_type(fake_attr, action_type)
        end)

      %{
        "anyOf" => subtypes
      }
      |> unwrap_any_of()
    end

    defp resource_write_attribute_type(%{type: type} = attr, action_type) do
      if Ash.Type.embedded_type?(type) do
        embedded_type_input(attr, action_type)
      else
        if :erlang.function_exported(type, :json_write_schema, 1) do
          type.json_write_schema(attr.constraints)
        else
          resource_attribute_type(attr)
        end
      end
    end

    @spec resource_attribute_type(
            Ash.Resource.Attribute.t()
            | Ash.Resource.Actions.Argument.t()
            | Ash.Resource.Calculation.t()
            | Ash.Resource.Aggregate.t()
          ) ::
            Schema.t()
    defp resource_attribute_type(%{type: Ash.Type.String}) do
      %Schema{type: :string}
    end

    defp resource_attribute_type(%{type: Ash.Type.Boolean}) do
      %Schema{type: :boolean}
    end

    defp resource_attribute_type(%{type: Ash.Type.Integer}) do
      %Schema{type: :integer}
    end

    defp resource_attribute_type(%{type: Ash.Type.Float}) do
      %Schema{type: :number, format: :float}
    end

    defp resource_attribute_type(%{type: Ash.Type.UtcDatetime}) do
      %Schema{
        type: :string,
        format: "date-time"
      }
    end

    defp resource_attribute_type(%{type: Ash.Type.UUID}) do
      %Schema{
        type: :string,
        format: "uuid"
      }
    end

    defp resource_attribute_type(%{type: Ash.Type.Atom, constraints: constraints}) do
      if one_of = constraints[:one_of] do
        %Schema{
          type: :string,
          enum: one_of
        }
      else
        %Schema{
          type: :string
        }
      end
    end

    defp resource_attribute_type(%{type: Ash.Type.Union, constraints: constraints} = attr) do
      subtypes =
        Enum.map(constraints[:types], fn {_name, config} ->
          fake_attr = %{attr | type: config[:type], constraints: config[:constraints]}

          resource_attribute_type(fake_attr)
        end)

      %{
        "anyOf" => subtypes
      }
      |> unwrap_any_of()
    end

    defp resource_attribute_type(%{type: {:array, type}} = attr) do
      %Schema{
        type: :array,
        items:
          resource_attribute_type(%{
            attr
            | type: type,
              constraints: attr.constraints[:items] || []
          })
      }
    end

    defp resource_attribute_type(%{type: type} = attr) do
      constraints = attr.constraints

      cond do
        Ash.Type.embedded_type?(type) ->
          %Schema{
            type: :object,
            properties: resource_attributes(type),
            required: required_attributes(type)
          }

        function_exported?(type, :json_schema, 1) ->
          type.json_schema(constraints)

        Ash.Type.NewType.new_type?(type) ->
          new_constraints = Ash.Type.NewType.constraints(type, constraints)
          new_type = Ash.Type.NewType.subtype_of(type)

          resource_attribute_type(
            Map.merge(attr, %{type: new_type, constraints: new_constraints})
          )

        Spark.implements_behaviour?(type, Ash.Type.Enum) ->
          %Schema{
            type: :string,
            enum: type.values()
          }

        true ->
          %Schema{}
      end
    end

    defp embedded_type_input(%{type: resource} = attribute, action_type) do
      attribute = %{
        attribute
        | constraints: Ash.Type.NewType.constraints(resource, attribute.constraints)
      }

      resource = Ash.Type.NewType.subtype_of(resource)

      create_action =
        case attribute.constraints[:create_action] do
          nil ->
            Ash.Resource.Info.primary_action!(resource, :create)

          name ->
            Ash.Resource.Info.action(resource, name)
        end

      update_action =
        case attribute.constraints[:update_action] do
          nil ->
            Ash.Resource.Info.primary_action!(resource, :update)

          name ->
            Ash.Resource.Info.action(resource, name)
        end

      create_write_attributes =
        write_attributes(resource, create_action.arguments, create_action)

      update_write_attributes =
        write_attributes(resource, update_action.arguments, update_action)

      create_required_attributes =
        required_write_attributes(resource, create_action.arguments, create_action)

      update_required_attributes =
        required_write_attributes(resource, update_action.arguments, update_action)

      required =
        if action_type == :create do
          create_required_attributes
        else
          create_required_attributes
          |> MapSet.new()
          |> MapSet.intersection(MapSet.new(update_required_attributes))
          |> Enum.to_list()
        end

      %Schema{
        type: :object,
        properties:
          Map.merge(create_write_attributes, update_write_attributes, fn _k, l, r ->
            %{
              "anyOf" => [
                l,
                r
              ]
            }
            |> unwrap_any_of()
          end),
        required: required
      }
    end

    defp unwrap_any_of(%{"anyOf" => options}) do
      {options_remaining, options_to_add} =
        Enum.reduce(options, {[], []}, fn schema, {options, to_add} ->
          case schema do
            %{"anyOf" => _} = schema ->
              case unwrap_any_of(schema) do
                %{"anyOf" => nested_options} ->
                  {options, [nested_options | to_add]}

                schema ->
                  {options, [schema | to_add]}
              end

            _ ->
              {[schema | to_add], options}
          end
        end)

      case options_remaining ++ options_to_add do
        [] ->
          %{"type" => "any"}

        [one] ->
          one

        many ->
          %{"anyOf" => many}
      end
    end

    @spec with_attribute_description(
            Schema.t(),
            Ash.Resource.Attribute.t() | Ash.Resource.Actions.Argument.t()
          ) :: Schema.t()
    defp with_attribute_description(schema, %{description: nil}) do
      schema
    end

    defp with_attribute_description(schema, %{description: description}) do
      Map.merge(schema, %{description: description})
    end

    @spec relationships(resource :: Ash.Resource.t()) :: Schema.t()
    defp relationships(resource) do
      %Schema{
        description: "A relationships object for a #{AshJsonApi.Resource.Info.type(resource)}",
        type: :object,
        properties: resource_relationships(resource),
        additionalProperties: false
      }
    end

    @spec resource_relationships(resource :: module) :: %{atom => Schema.t()}
    defp resource_relationships(resource) do
      resource
      |> Ash.Resource.Info.public_relationships()
      |> Enum.filter(fn %{destination: relationship} ->
        AshJsonApi.Resource.Info.type(relationship)
      end)
      |> Map.new(fn rel ->
        data = resource_relationship_field_data(resource, rel)
        links = resource_relationship_link_data(resource, rel)

        object =
          if links do
            %Schema{properties: %{data: data, links: links}}
          else
            %Schema{properties: %{data: data}}
          end

        {rel.name, object}
      end)
    end

    defp resource_relationship_link_data(_resource, _rel) do
      nil
    end

    @spec resource_relationship_field_data(
            resource :: module,
            Relationships.relationship()
          ) :: Schema.t()
    defp resource_relationship_field_data(_resource, %{
           type: {:array, _},
           name: name
         }) do
      %Schema{
        description: "Identifiers for #{name}",
        type: :object,
        nullable: true,
        required: [:type, :id],
        additionalProperties: false,
        properties: %{
          type: %Schema{type: :string},
          id: %Schema{type: :string},
          meta: %Schema{
            type: :object,
            additionalProperties: true
          }
        }
      }
    end

    defp resource_relationship_field_data(_resource, %{
           name: name
         }) do
      %Schema{
        description: "An array of inputs for #{name}",
        type: :array,
        items: %{
          description: "Resource identifiers for #{name}",
          type: :object,
          required: [:type, :id],
          properties: %{
            type: %Schema{type: :string},
            id: %Schema{type: :string},
            meta: %Schema{
              type: :object,
              additionalProperties: true
            }
          }
        },
        uniqueItems: true
      }
    end

    @doc """
    Tags based on resource names to include in the API spec
    """
    @spec tags(domain :: module | [module]) :: [Tag.t()]
    def tags(domains) when is_list(domains) do
      Enum.flat_map(domains, &tags/1)
    end

    def tags(domain) do
      tag = AshJsonApi.Domain.Info.tag(domain)
      group_by = AshJsonApi.Domain.Info.group_by(domain)

      if tag && group_by == :domain do
        [
          %Tag{
            name: to_string(tag),
            description: "Operations on the #{tag} API."
          }
        ]
      else
        domain
        |> resources()
        |> Enum.map(fn resource ->
          name = AshJsonApi.Resource.Info.type(resource)

          %Tag{
            name: to_string(name),
            description: "Operations on the #{name} resource."
          }
        end)
      end
    end

    @doc """
    Paths (routes) from the domain.
    """
    @spec paths(domain :: module | [module], module | [module]) :: Paths.t()
    def paths(domains, all_domains) when is_list(domains) do
      domains
      |> Enum.map(&paths(&1, all_domains))
      |> Enum.reduce(&Map.merge/2)
    end

    def paths(domain, all_domains) do
      domain
      |> resources()
      |> Enum.flat_map(fn resource ->
        resource
        |> AshJsonApi.Resource.Info.routes(all_domains)
        |> Enum.map(&route_operation(&1, domain, resource))
      end)
      |> Enum.group_by(fn {path, _route_op} -> path end, fn {_path, route_op} -> route_op end)
      |> Map.new(fn {path, route_ops} -> {path, struct!(PathItem, route_ops)} end)
    end

    @spec route_operation(Route.t(), domain :: module, resource :: module) ::
            {Paths.path(), {verb :: atom, Operation.t()}}
    defp route_operation(route, domain, resource) do
      resource =
        if route.relationship do
          Ash.Resource.Info.related(resource, route.relationship)
        else
          resource
        end

      tag = AshJsonApi.Domain.Info.tag(domain)
      group_by = AshJsonApi.Domain.Info.group_by(domain)

      {path, path_params} = AshJsonApi.JsonSchema.route_href(route, domain)
      operation = operation(route, resource, path_params)

      operation =
        if tag && group_by === :domain do
          Map.merge(operation, %{tags: [to_string(tag)]})
        else
          operation
        end

      {path, {route.method, operation}}
    end

    @spec operation(Route.t(), resource :: module, path_params :: [String.t()]) ::
            Operation.t()
    defp operation(route, resource, path_params) do
      action = Ash.Resource.Info.action(resource, route.action)

      if !action do
        raise """
        No such action #{inspect(route.action)} for #{inspect(resource)}

        You likely have an incorrectly configured route.
        """
      end

      response_code =
        case route.method do
          :post -> 201
          _ -> 200
        end

      %Operation{
        description: action_description(action, route, resource),
        operationId: route.name,
        tags: [to_string(AshJsonApi.Resource.Info.type(resource))],
        parameters: path_parameters(path_params, action) ++ query_parameters(route, resource),
        responses: %{
          :default => %Reference{
            "$ref": "#/components/responses/errors"
          },
          response_code => response_body(route, resource)
        },
        requestBody: request_body(route, resource)
      }
    end

    defp action_description(action, route, resource) do
      action.description || default_description(route, resource)
    end

    defp default_description(route, resource) do
      if route.name do
        "#{route.name} operation on #{AshJsonApi.Resource.Info.type(resource)} resource"
      else
        "#{route.route} operation on #{AshJsonApi.Resource.Info.type(resource)} resource"
      end
    end

    @spec path_parameters(path_params :: [String.t()], action :: Actions.action()) ::
            [Parameter.t()]
    defp path_parameters(path_params, action) do
      Enum.map(path_params, fn param ->
        description =
          action.arguments
          |> Enum.find(&(to_string(&1.name) == param))
          |> case do
            %{description: description} when is_binary(description) -> description
            _ -> nil
          end

        %Parameter{
          name: param,
          description: description,
          in: :path,
          required: true,
          schema: %Schema{type: :string}
        }
      end)
    end

    @spec query_parameters(
            Route.t(),
            resource :: module
          ) :: [Parameter.t()]
    defp query_parameters(%{type: :index} = route, resource) do
      Enum.filter(
        [
          filter_parameter(resource, route),
          sort_parameter(resource, route),
          page_parameter(Ash.Resource.Info.action(resource, route.action)),
          include_parameter(),
          fields_parameter(resource)
        ],
        & &1
      ) ++
        read_argument_parameters(route, resource)
    end

    defp query_parameters(%{type: type}, _resource)
         when type in [
                :post_to_relationship,
                :patch_relationship,
                :delete_from_relationship,
                :route
              ] do
      []
    end

    defp query_parameters(%{type: type} = route, resource) when type in [:get, :related] do
      [include_parameter(), fields_parameter(resource)] ++
        read_argument_parameters(route, resource)
    end

    defp query_parameters(_route, resource) do
      [include_parameter(), fields_parameter(resource)]
    end

    @spec filter_parameter(resource :: module, route :: AshJsonApi.Resource.Route.t()) ::
            Parameter.t()
    defp filter_parameter(resource, route) do
      if route.derive_filter? && read_action?(resource, route) &&
           AshJsonApi.Resource.Info.derive_filter?(resource) do
        %Parameter{
          name: :filter,
          in: :query,
          description:
            "Filters the query to results with attributes matching the given filter object",
          required: false,
          style: :deepObject,
          schema: %Reference{
            "$ref": "#/components/schemas/#{AshJsonApi.Resource.Info.type(resource)}-filter"
          }
        }
      end
    end

    @spec sort_parameter(resource :: module, route :: AshJsonApi.Resource.Route.t()) ::
            Parameter.t()
    defp sort_parameter(resource, route) do
      if route.derive_sort? && read_action?(resource, route) &&
           AshJsonApi.Resource.Info.derive_sort?(resource) do
        sorts =
          resource
          |> AshJsonApi.JsonSchema.sortable_fields()
          |> Enum.flat_map(fn attr ->
            name = to_string(attr.name)
            [name, "-" <> name]
          end)

        %Parameter{
          name: :sort,
          in: :query,
          description: "Sort order to apply to the results",
          required: false,
          style: :form,
          explode: false,
          schema: %Schema{
            type: :array,
            items: %Schema{
              type: :string,
              enum: sorts
            }
          }
        }
      end
    end

    @spec page_parameter(term()) :: Parameter.t()
    defp page_parameter(action) do
      if action.type == :read && action.pagination &&
           (action.pagination.keyset? || action.pagination.offset?) do
        cond do
          action.pagination.keyset? && action.pagination.offset? ->
            %Parameter{
              name: :page,
              in: :query,
              description:
                "Paginates the response with the limit and offset or keyset pagination.",
              required: action.pagination.required? && !action.pagination.default_limit,
              style: :deepObject,
              schema: %Schema{
                anyOf: [
                  keyset_pagination_schema(action.pagination),
                  offset_pagination_schema(action.pagination)
                ]
              }
            }

          action.pagination.keyset? ->
            %Parameter{
              name: :page,
              in: :query,
              description:
                "Paginates the response with the limit and offset or keyset pagination.",
              required: action.pagination.required? && !action.pagination.default_limit,
              style: :deepObject,
              schema: keyset_pagination_schema(action.pagination)
            }

          action.pagination.offset? ->
            %Parameter{
              name: :page,
              in: :query,
              description:
                "Paginates the response with the limit and offset or keyset pagination.",
              required: action.pagination.required? && !action.pagination.default_limit,
              style: :deepObject,
              schema: offset_pagination_schema(action.pagination)
            }
        end
      end
    end

    defp offset_pagination_schema(pagination) do
      %Schema{
        type: :object,
        properties:
          %{
            limit: %Schema{type: :integer, minimum: 1},
            offset: %Schema{type: :integer, minimum: 0}
          }
          |> add_count(pagination)
      }
    end

    defp keyset_pagination_schema(pagination) do
      %Schema{
        type: :object,
        properties:
          %{
            limit: %Schema{type: :integer, minimum: 1},
            after: %Schema{type: :string},
            before: %Schema{type: :string}
          }
          |> add_count(pagination)
      }
    end

    defp add_count(props, pagination) do
      if pagination.countable do
        Map.put(props, :count, %Schema{
          type: :boolean,
          default: pagination.countable == :by_default
        })
      else
        props
      end
    end

    @spec include_parameter() :: Parameter.t()
    defp include_parameter do
      %Parameter{
        name: :include,
        in: :query,
        required: false,
        description: "Relationship paths to include in the response",
        style: :form,
        explode: false,
        schema: %Schema{
          type: :array,
          items: %Schema{
            type: :string,
            pattern: ~r/^[a-zA-Z_]\w*(\.[a-zA-Z_]\w*)*$/
          }
        }
      }
    end

    @spec fields_parameter(resource :: module) :: Parameter.t()
    defp fields_parameter(resource) do
      type = AshJsonApi.Resource.Info.type(resource)

      %Parameter{
        name: :fields,
        in: :query,
        description: "Limits the response fields to only those listed for each type",
        required: false,
        style: :deepObject,
        schema: %Schema{
          type: :object,
          additionalProperties: true,
          properties: %{
            # There is a static set of types (one per resource)
            # so this is safe.
            #
            # sobelow_skip ["DOS.StringToAtom"]
            String.to_atom(type) => %Schema{
              description: "Comma separated field names for #{type}",
              type: :string,
              example:
                Ash.Resource.Info.public_attributes(resource)
                |> Enum.map_join(",", & &1.name)
            }
          }
        }
      }
    end

    @spec read_argument_parameters(Route.t(), resource :: module) :: [Parameter.t()]
    defp read_argument_parameters(route, resource) do
      action = Ash.Resource.Info.action(resource, route.action)

      action.arguments
      |> Enum.filter(& &1.public?)
      |> Enum.map(fn argument ->
        schema = resource_attribute_type(argument)

        %Parameter{
          name: argument.name,
          in: :query,
          description: argument.description || to_string(argument.name),
          required: !argument.allow_nil?,
          style:
            case schema.type do
              :object -> :deepObject
              _ -> :form
            end,
          schema: schema
        }
      end)
    end

    @spec request_body(Route.t(), resource :: module) :: nil | RequestBody.t()
    defp request_body(%{method: method}, _resource)
         when method in [:get, :delete] do
      nil
    end

    defp request_body(route, resource) do
      body_schema = request_body_schema(route, resource)

      if route.type == :route && Enum.empty?(body_schema.properties.data.properties) do
        nil
      else
        body_required =
          if route.type == :route do
            body_schema.properties.data.required != []
          else
            body_schema.properties.data.properties.attributes.required != [] ||
              body_schema.properties.data.properties.relationships.required != []
          end

        %RequestBody{
          description:
            "Request body for the #{route.name || route.route} operation on #{AshJsonApi.Resource.Info.type(resource)} resource",
          required: body_required,
          content: %{
            "application/vnd.api+json" => %MediaType{schema: body_schema}
          }
        }
      end
    end

    @spec request_body_schema(Route.t(), resource :: module) :: Schema.t()
    defp request_body_schema(
           %{
             type: :route,
             action: action
           } = route,
           resource
         ) do
      action = Ash.Resource.Info.action(resource, action)

      %Schema{
        type: :object,
        required: [:data],
        additionalProperties: false,
        properties: %{
          data: %Schema{
            type: :object,
            additionalProperties: false,
            properties:
              write_attributes(
                resource,
                action.arguments,
                action,
                route
              ),
            required: required_write_attributes(resource, action.arguments, action, route)
          }
        }
      }
    end

    defp request_body_schema(
           %{
             type: :post,
             action: action,
             relationship_arguments: relationship_arguments
           } = route,
           resource
         ) do
      action = Ash.Resource.Info.action(resource, action)

      non_relationship_arguments =
        Enum.reject(
          action.arguments,
          &has_relationship_argument?(relationship_arguments, &1.name)
        )

      %Schema{
        type: :object,
        required: [:data],
        additionalProperties: false,
        properties: %{
          data: %Schema{
            type: :object,
            additionalProperties: false,
            properties: %{
              type: %Schema{
                enum: [AshJsonApi.Resource.Info.type(resource)]
              },
              attributes: %Schema{
                type: :object,
                additionalProperties: false,
                properties:
                  write_attributes(
                    resource,
                    non_relationship_arguments,
                    action,
                    route
                  ),
                required:
                  required_write_attributes(resource, non_relationship_arguments, action, route)
              },
              relationships: %Schema{
                type: :object,
                additionalProperties: false,
                properties: write_relationships(resource, relationship_arguments, action),
                required:
                  required_relationship_attributes(resource, relationship_arguments, action)
              }
            }
          }
        }
      }
    end

    defp request_body_schema(
           %{
             type: :patch,
             action: action,
             relationship_arguments: relationship_arguments
           } = route,
           resource
         ) do
      action = Ash.Resource.Info.action(resource, action)

      non_relationship_arguments =
        Enum.reject(
          action.arguments,
          &has_relationship_argument?(relationship_arguments, &1.name)
        )

      %Schema{
        type: :object,
        required: [:data],
        additionalProperties: false,
        properties: %{
          data: %Schema{
            type: :object,
            additionalProperties: false,
            required: [:id],
            properties: %{
              id: %Schema{
                type: :string
              },
              type: %Schema{
                enum: [AshJsonApi.Resource.Info.type(resource)]
              },
              attributes: %Schema{
                type: :object,
                additionalProperties: false,
                properties:
                  write_attributes(
                    resource,
                    non_relationship_arguments,
                    action,
                    route
                  ),
                required:
                  required_write_attributes(resource, non_relationship_arguments, action, route)
              },
              relationships: %Schema{
                type: :object,
                additionalProperties: false,
                properties: write_relationships(resource, relationship_arguments, action),
                required:
                  required_relationship_attributes(resource, relationship_arguments, action)
              }
            }
          }
        }
      }
    end

    defp request_body_schema(
           %{type: type, relationship: relationship},
           resource
         )
         when type in [:post_to_relationship, :patch_relationship, :delete_from_relationship] do
      resource
      |> Ash.Resource.Info.public_relationship(relationship)
      |> relationship_resource_identifiers()
    end

    defp required_write_attributes(resource, arguments, action, route \\ nil) do
      attributes =
        if action.type == :action do
          []
        else
          resource
          |> Ash.Resource.Info.attributes()
          |> Enum.filter(&(&1.name in action.accept && &1.writable?))
          |> Enum.reject(&(&1.allow_nil? || not is_nil(&1.default) || &1.generated?))
          |> Enum.map(& &1.name)
        end

      arguments =
        arguments
        |> without_path_arguments(action, route)
        |> Enum.reject(& &1.allow_nil?)
        |> Enum.map(& &1.name)

      Enum.uniq(attributes ++ arguments ++ Map.get(action, :require_attributes, []))
    end

    @spec write_attributes(
            resource :: module,
            [Ash.Resource.Actions.Argument.t()],
            action :: term()
          ) :: %{atom => Schema.t()}
    defp write_attributes(resource, arguments, action, route \\ nil) do
      attributes =
        if action.type == :action do
          %{}
        else
          resource
          |> Ash.Resource.Info.attributes()
          |> Enum.filter(&(&1.name in action.accept && &1.writable?))
          |> Map.new(fn attribute ->
            {attribute.name, resource_write_attribute_type(attribute, action.type)}
          end)
        end

      arguments
      |> without_path_arguments(action, route)
      |> Enum.reduce(attributes, fn argument, attributes ->
        Map.put(attributes, argument.name, resource_write_attribute_type(argument, :create))
      end)
    end

    defp without_path_arguments(arguments, %{type: :action}, %{route: route}) do
      route_params =
        route
        |> Path.split()
        |> Enum.filter(&String.starts_with?(&1, ":"))
        |> Enum.map(&String.trim_leading(&1, ":"))

      Enum.reject(arguments, fn argument ->
        to_string(argument.name) in route_params
      end)
    end

    defp without_path_arguments(arguments, _, _), do: arguments

    @spec required_relationship_attributes(
            resource :: module,
            [Actions.Argument.t()],
            Actions.action()
          ) :: [atom()]
    defp required_relationship_attributes(_resource, relationship_arguments, action) do
      action.arguments
      |> Enum.filter(&has_relationship_argument?(relationship_arguments, &1.name))
      |> Enum.reject(& &1.allow_nil?)
      |> Enum.map(& &1.name)
    end

    @spec write_relationships(resource :: module, [Actions.Argument.t()], Actions.action()) ::
            %{atom() => Schema.t()}
    defp write_relationships(resource, relationship_arguments, action) do
      action.arguments
      |> Enum.filter(&has_relationship_argument?(relationship_arguments, &1.name))
      |> Map.new(fn argument ->
        data = resource_relationship_field_data(resource, argument)

        schema = %Schema{
          type: :object,
          properties: %{
            data: data,
            links: %Schema{type: :object, additionalProperties: true}
          }
        }

        {argument.name, schema}
      end)
    end

    @spec has_relationship_argument?(relationship_arguments :: list, name :: atom) :: boolean()
    defp has_relationship_argument?(relationship_arguments, name) do
      Enum.any?(relationship_arguments, fn
        {:id, ^name} -> true
        ^name -> true
        _ -> false
      end)
    end

    @spec response_body(Route.t(), resource :: module) :: Response.t()
    defp response_body(%{method: :delete}, _resource) do
      %Response{
        description: "Deleted successfully"
      }
    end

    defp response_body(route, resource) do
      %Response{
        description: "Success",
        content: %{
          "application/vnd.api+json" => %MediaType{
            schema: response_schema(route, resource)
          }
        }
      }
    end

    @spec response_schema(Route.t(), resource :: module) :: Schema.t()
    defp response_schema(route, resource) do
      case route.type do
        :route ->
          action = Ash.Resource.Info.action(resource, route.action)

          return_type =
            resource_attribute_type(%{type: action.returns, constraints: action.constraints})

          if route.wrap_in_result? do
            %Schema{
              type: :object,
              properties: %{
                result: return_type
              },
              required: [:result]
            }
          else
            return_type
          end

        :index ->
          %Schema{
            type: :object,
            properties: %{
              data: %Schema{
                description:
                  "An array of resource objects representing a #{AshJsonApi.Resource.Info.type(resource)}",
                type: :array,
                items: item_reference(route, resource),
                uniqueItems: true
              },
              included: included_resource_schemas(resource),
              meta: %Schema{
                type: :object,
                additionalProperties: true
              }
            }
          }

        :delete ->
          nil

        type
        when type in [:post_to_relationship, :patch_relationship, :delete_from_relationship] ->
          resource
          |> Ash.Resource.Info.public_relationship(route.relationship)
          |> relationship_resource_identifiers()

        _ ->
          %Schema{
            properties: %{
              data: item_reference(route, resource),
              included: included_resource_schemas(resource),
              meta: %Schema{
                type: :object,
                additionalProperties: true
              }
            }
          }
      end
    end

    defp item_reference(%{default_fields: nil}, resource) do
      %Reference{
        "$ref": "#/components/schemas/#{AshJsonApi.Resource.Info.type(resource)}"
      }
    end

    defp item_reference(%{default_fields: default_fields}, resource) do
      resource_object_schema(resource, default_fields)
    end

    @spec relationship_resource_identifiers(relationship :: Relationships.relationship()) ::
            Schema.t()
    defp relationship_resource_identifiers(relationship) do
      %Schema{
        type: :object,
        required: [:data],
        additionalProperties: false,
        properties: %{
          data: %{
            type: :array,
            items: %{
              type: :object,
              required: [:id, :type],
              additionalProperties: false,
              properties: %{
                id: %Schema{
                  type: :string
                },
                type: %Schema{
                  enum: [AshJsonApi.Resource.Info.type(relationship.destination)]
                },
                meta: %Schema{
                  type: :object,
                  additionalProperties: true
                }
              }
            }
          }
        }
      }
    end

    defp included_resource_schemas(resource) do
      includes = AshJsonApi.Resource.Info.includes(resource)
      include_resources = includes_to_resources(resource, includes)

      include_schemas =
        include_resources
        |> Enum.filter(&AshJsonApi.Resource.Info.type(&1))
        |> Enum.map(fn resource ->
          %Reference{"$ref": "#/components/schemas/#{AshJsonApi.Resource.Info.type(resource)}"}
        end)

      %Schema{
        type: :array,
        uniqueItems: true,
        items: %Schema{
          oneOf: include_schemas
        }
      }
    end

    defp includes_to_resources(nil, _), do: []

    defp includes_to_resources(resource, includes) when is_list(includes) do
      includes
      |> Enum.flat_map(fn
        {include, []} ->
          relationship_destination(resource, include) |> List.wrap()

        {include, includes} ->
          case relationship_destination(resource, include) do
            nil ->
              []

            resource ->
              [resource | includes_to_resources(resource, includes)]
          end

        include ->
          relationship_destination(resource, include) |> List.wrap()
      end)
      |> Enum.uniq()
    end

    defp includes_to_resources(resource, include),
      do: relationship_destination(resource, include) |> List.wrap()

    defp relationship_destination(resource, include) do
      resource
      |> Ash.Resource.Info.public_relationship(include)
      |> case do
        %{destination: destination} -> destination
        _ -> nil
      end
    end

    defp filter_field_types(resource) do
      filter_attribute_types(resource) ++
        filter_aggregate_types(resource) ++
        filter_calculation_types(resource)
    end

    defp filter_attribute_types(resource) do
      resource
      |> Ash.Resource.Info.public_attributes()
      |> Enum.filter(&filterable?(&1, resource))
      |> Enum.flat_map(&filter_type(&1, resource))
    end

    defp filter_aggregate_types(resource) do
      resource
      |> Ash.Resource.Info.public_aggregates()
      |> Enum.filter(&filterable?(&1, resource))
      |> Enum.flat_map(&filter_type(&1, resource))
    end

    defp filter_calculation_types(resource) do
      resource
      |> Ash.Resource.Info.public_calculations()
      |> Enum.filter(&filterable?(&1, resource))
      |> Enum.flat_map(&filter_type(&1, resource))
    end

    defp attribute_or_aggregate_type(%Ash.Resource.Attribute{type: type}, _resource),
      do: type

    defp attribute_or_aggregate_type(%Ash.Resource.Calculation{type: type}, _resource),
      do: type

    defp attribute_or_aggregate_type(
           %Ash.Resource.Aggregate{
             kind: kind,
             field: field,
             relationship_path: relationship_path
           },
           resource
         ) do
      field_type =
        with field when not is_nil(field) <- field,
             related when not is_nil(related) <-
               Ash.Resource.Info.related(resource, relationship_path),
             attr when not is_nil(attr) <- Ash.Resource.Info.field(related, field) do
          attr.type
        end

      {:ok, aggregate_type, _} = Ash.Query.Aggregate.kind_to_type(kind, field_type, [])

      aggregate_type
    end

    @doc false
    def filter_type(attribute_or_aggregate, resource) do
      type = attribute_or_aggregate_type(attribute_or_aggregate, resource)

      array_type? = match?({:array, _}, type)

      fields =
        Ash.Filter.builtin_operators()
        |> Enum.concat(Ash.DataLayer.functions(resource))
        |> Enum.filter(& &1.predicate?())
        |> restrict_for_lists(type)
        |> Enum.flat_map(fn operator ->
          filter_fields(operator, type, array_type?, attribute_or_aggregate, resource)
        end)

      if fields == [] do
        []
      else
        [
          {attribute_filter_field_type(resource, attribute_or_aggregate),
           %Schema{
             type: :object,
             properties: Map.new(fields),
             additionalProperties: false
           }}
        ]
      end
    end

    defp attribute_filter_field_type(resource, attribute) do
      AshJsonApi.Resource.Info.type(resource) <> "-filter-" <> to_string(attribute.name)
    end

    defp resource_filter_fields(resource) do
      Enum.concat([
        boolean_filter_fields(resource),
        attribute_filter_fields(resource),
        relationship_filter_fields(resource),
        aggregate_filter_fields(resource),
        calculation_filter_fields(resource)
      ])
      |> Map.new()
    end

    defp relationship_filter_fields(resource) do
      resource
      |> Ash.Resource.Info.public_relationships()
      |> Enum.filter(
        &(AshJsonApi.Resource.Info.derive_filter?(&1.destination) &&
            AshJsonApi.Resource in Spark.extensions(&1.destination) &&
            AshJsonApi.Resource.Info.type(&1.destination))
      )
      |> Enum.map(fn relationship ->
        {relationship.name,
         %Reference{
           "$ref":
             "#/components/schemas/#{AshJsonApi.Resource.Info.type(relationship.destination)}-filter"
         }}
      end)
    end

    defp calculation_filter_fields(resource) do
      if Ash.DataLayer.data_layer_can?(resource, :expression_calculation) do
        resource
        |> Ash.Resource.Info.public_calculations()
        |> Enum.filter(&filterable?(&1, resource))
        |> Enum.map(fn calculation ->
          {calculation.name,
           %Reference{
             "$ref": "#/components/schemas/#{attribute_filter_field_type(resource, calculation)}"
           }}
        end)
      else
        []
      end
    end

    defp attribute_filter_fields(resource) do
      resource
      |> Ash.Resource.Info.public_attributes()
      |> Enum.filter(&filterable?(&1, resource))
      |> Enum.map(fn attribute ->
        {attribute.name,
         %Reference{
           "$ref": "#/components/schemas/#{attribute_filter_field_type(resource, attribute)}"
         }}
      end)
    end

    defp aggregate_filter_fields(resource) do
      if Ash.DataLayer.data_layer_can?(resource, :aggregate_filter) do
        resource
        |> Ash.Resource.Info.public_aggregates()
        |> Enum.filter(&filterable?(&1, resource))
        |> Enum.map(fn aggregate ->
          {aggregate.name,
           %Reference{
             "$ref": "#/components/schemas/#{attribute_filter_field_type(resource, aggregate)}"
           }}
        end)
      else
        []
      end
    end

    defp boolean_filter_fields(resource) do
      if Ash.DataLayer.can?(:boolean_filter, resource) do
        [
          and: %Reference{
            "$ref": "#/components/schemas/#{AshJsonApi.Resource.Info.type(resource)}-filter"
          },
          or: %Reference{
            "$ref": "#/components/schemas/#{AshJsonApi.Resource.Info.type(resource)}-filter"
          },
          not: %Reference{
            "$ref": "#/components/schemas/#{AshJsonApi.Resource.Info.type(resource)}-filter"
          }
        ]
      else
        []
      end
    end

    defp restrict_for_lists(operators, {:array, _}) do
      list_predicates = [Ash.Query.Operator.IsNil, Ash.Query.Operator.Has]
      Enum.filter(operators, &(&1 in list_predicates))
    end

    defp restrict_for_lists(operators, _), do: operators

    defp constraints_to_item_constraints(
           {:array, _},
           %Ash.Resource.Attribute{
             constraints: constraints,
             allow_nil?: allow_nil?
           } = attribute
         ) do
      %{
        attribute
        | constraints: [
            items: constraints,
            nil_items?: allow_nil? || AshJsonApi.JsonSchema.embedded?(attribute.type)
          ]
      }
    end

    defp constraints_to_item_constraints(_, attribute_or_aggregate), do: attribute_or_aggregate

    defp get_expressable_types(operator_or_function, field_type, array_type?) do
      if :attributes
         |> operator_or_function.__info__()
         |> Keyword.get_values(:behaviour)
         |> List.flatten()
         |> Enum.any?(&(&1 == Ash.Query.Operator)) do
        do_get_expressable_types(operator_or_function.types(), field_type, array_type?)
      else
        do_get_expressable_types(operator_or_function.args(), field_type, array_type?)
      end
    end

    defp do_get_expressable_types(operator_types, field_type, array_type?) do
      field_type_short_name =
        case Ash.Type.short_names()
             |> Enum.find(fn {_, type} -> type == field_type end) do
          nil -> nil
          {short_name, _} -> short_name
        end

      operator_types
      |> Enum.filter(fn
        [:any, {:array, type}] when is_atom(type) ->
          true

        [{:array, inner_type}, :same] when is_atom(inner_type) and array_type? ->
          true

        :same ->
          true

        :any ->
          true

        [:any, type] when is_atom(type) ->
          true

        [^field_type_short_name, type] when is_atom(type) and not is_nil(field_type_short_name) ->
          true

        _ ->
          false
      end)
    end

    defp filter_fields(
           operator,
           type,
           array_type?,
           attribute_or_aggregate,
           _resource
         ) do
      expressable_types = get_expressable_types(operator, type, array_type?)

      if Enum.any?(expressable_types, &(&1 == :same)) do
        [
          {operator.name(), resource_attribute_type(attribute_or_aggregate)}
        ]
      else
        type =
          case Enum.at(expressable_types, 0) do
            [{:array, :any}, :same] ->
              {:unwrap, type}

            [_, {:array, :same}] ->
              {:array, type}

            [_, :same] ->
              type

            [_, :any] ->
              Ash.Type.String

            [_, type] when is_atom(type) ->
              Ash.Type.get_type(type)

            _ ->
              nil
          end

        if type do
          {type, attribute_or_aggregate} =
            case type do
              {:unwrap, type} ->
                {:array, type} = type
                {type, %{attribute_or_aggregate | type: type, constraints: []}}

              type ->
                {type, %{attribute_or_aggregate | type: type, constraints: []}}
            end

          if AshJsonApi.JsonSchema.embedded?(type) do
            []
          else
            attribute_or_aggregate = constraints_to_item_constraints(type, attribute_or_aggregate)

            [
              {operator.name(), resource_attribute_type(attribute_or_aggregate)}
            ]
          end
        else
          []
        end
      end
    rescue
      _e ->
        []
    end

    defp filterable?(%Ash.Resource.Aggregate{} = aggregate, resource) do
      attribute =
        with field when not is_nil(field) <- aggregate.field,
             related when not is_nil(related) <-
               Ash.Resource.Info.related(resource, aggregate.relationship_path),
             attr when not is_nil(attr) <- Ash.Resource.Info.field(related, aggregate.field) do
          attr
        end

      field_type =
        if attribute do
          attribute.type
        end

      field_constraints =
        if attribute do
          attribute.constraints
        end

      {:ok, type, constraints} =
        Aggregate.kind_to_type(aggregate.kind, field_type, field_constraints)

      filterable?(
        %Ash.Resource.Attribute{name: aggregate.name, type: type, constraints: constraints},
        resource
      )
    end

    defp filterable?(%{type: {:array, _}}, _), do: false
    defp filterable?(%{filterable?: false}, _), do: false
    defp filterable?(%{type: Ash.Type.Union}, _), do: false

    defp filterable?(%Ash.Resource.Calculation{type: type, calculation: {module, _opts}}, _) do
      !AshJsonApi.JsonSchema.embedded?(type) && function_exported?(module, :expression, 2)
    end

    defp filterable?(%{type: type} = attribute, resource) do
      if Ash.Type.NewType.new_type?(type) do
        filterable?(
          %{
            attribute
            | constraints: Ash.Type.NewType.constraints(type, attribute.constraints),
              type: Ash.Type.NewType.subtype_of(type)
          },
          resource
        )
      else
        !AshJsonApi.JsonSchema.embedded?(type)
      end
    end

    defp filterable?(_, _), do: false
  end
end
