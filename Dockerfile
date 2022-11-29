FROM elixir:1.13.4 as build
WORKDIR /build

COPY . .

RUN export MIX_ENV=prod && \
    mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    mix release

FROM elixir:1.13.4
EXPOSE 4369
WORKDIR /app
COPY --from=build /build/_build/prod/rel/mc714_p2 .
COPY entrypoint.sh .
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["start"]
