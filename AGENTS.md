This is an Elixir library for associating media files with Ecto schemas, inspired by Spatie's Laravel Media Library.

## Project overview

PhxMediaLibrary provides a simple, fluent API for:
- Associating files with Ecto schemas
- Organizing media into collections
- Storing files across different storage backends
- Generating derived images (thumbnails, conversions)
- Handling file uploads

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use `:req` (`Req`) library for HTTP requests (e.g., downloading remote files), **avoid** `:httpoison`, `:tesla`, and `:httpc`
- This is a **library**, not an application - design APIs to be flexible and composable
- Follow semantic versioning for releases

### Library design principles

- **Provide sensible defaults** but allow configuration at every level
- **Avoid global configuration** where possible - prefer passing options explicitly or using schema-level configuration
- **Use behaviours** for extensibility (storage adapters, image processors, etc.)
- **Keep dependencies minimal** - make heavy dependencies optional where feasible
- **Write comprehensive documentation** - every public function needs `@doc` and `@spec`
- **Design fluent APIs** that are pleasant to use, similar to Spatie's approach:

      post
      |> Media.add(upload)
      |> Media.to_collection("images")
      |> Media.with_conversions([:thumb, :preview])

### Documentation guidelines

- **Always** write `@moduledoc` for every module explaining its purpose
- **Always** write `@doc` for every public function with examples
- **Always** write `@spec` typespecs for all public functions
- Use `@typedoc` for custom types
- Include usage examples in module docs that can be run as doctests
- Structure documentation to be readable on HexDocs

### Hex publishing guidelines

- Keep `mix.exs` metadata complete: `:description`, `:package`, `:source_url`, `:docs`
- Maintain a `CHANGELOG.md` with all notable changes
- **Never** publish with failing tests or missing documentation
- Use `mix hex.build --unpack` to verify package contents before publishing

## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

### Behaviours and protocols

- **Use behaviours** for defining contracts (storage adapters, processors)
- **Use protocols** when you need polymorphism across different data types
- **Always** provide a default implementation or clear error messages for required callbacks
- Document all callbacks with `@doc` and `@callback` specs

### Error handling

- **Return tagged tuples** (`{:ok, result}` / `{:error, reason}`) for operations that can fail
- Provide `!` bang versions for functions where appropriate (e.g., `add_media!/2`)
- Use custom exception structs for domain-specific errors
- **Never** raise exceptions for expected failure cases (e.g., file not found, invalid format)

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason
- Use `mix docs` to preview documentation locally before publishing
- Run `mix dialyzer` to catch type errors (if dialyxir is configured)

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages

### Library-specific testing

- **Test with real files** in a temporary directory that gets cleaned up after each test
- Use `tmp_dir` ExUnit tag or create fixtures in `test/support/fixtures/`
- **Test all storage adapters** with the same test suite using adapter-agnostic assertions
- Write integration tests that verify the full flow (add media → store → retrieve → convert)
- Use mocks sparingly - prefer testing against real implementations or in-memory adapters
- **Always** test error conditions and edge cases (missing files, invalid formats, storage failures)

## Ecto guidelines

- **Always** preload Ecto associations in queries when they'll be accessed together
- `Ecto.Schema` fields always use the `:string` type, even for `:text` columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such an option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied

### Media library Ecto patterns

- Design the media schema to be **polymorphic** - it should associate with any user schema via `belongs_to :mediable, ... , polymorphic: true` or similar pattern
- Store file metadata (size, mime type, dimensions) in the database for querying
- Use **JSON columns** for flexible metadata storage (custom properties, responsive image data)
- Provide migration generators for users to create the media table in their apps
- Consider soft deletes for media records to allow recovery

## File and storage guidelines

- **Abstract storage behind behaviours** - support local filesystem, S3, GCS, etc.
- **Never** trust user-provided filenames - sanitize and/or generate safe names
- Store files with **unique names** (UUIDs or hashes) to avoid collisions
- Preserve original filename in database metadata, not in the stored path
- **Calculate and store checksums** (MD5/SHA256) for integrity verification
- Support **streaming uploads** for large files to avoid memory issues
- Handle **mime type detection** properly - don't rely solely on file extensions

### Path conventions

- Use a consistent, predictable path structure: `{collection}/{id}/{conversion}/{filename}`
- Make paths configurable but provide sensible defaults
- Support both public and private file URLs
- Generate **signed/expiring URLs** for private storage backends

## Image processing guidelines

- **Make image processing optional** - don't require ImageMagick/libvips for basic usage
- Support multiple processing backends via behaviours (Image, Mogrify, Vix, etc.)
- Define conversions declaratively in the schema:

      conversions do
        convert :thumb, width: 100, height: 100, fit: :cover
        convert :preview, width: 800, quality: 85
      end

- Process conversions **asynchronously** by default (via Oban or similar)
- Store conversion status to track processing state
- Support **responsive images** (multiple sizes/srcset generation)
- Handle processing failures gracefully with retries and error reporting
