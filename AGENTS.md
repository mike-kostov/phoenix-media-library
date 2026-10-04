# AGENTS.md — PhxMediaLibrary

This file is the entrypoint for AI agents working in this repository.
It describes the project, the available skills, and when to use each one.

## About This Project

**PhxMediaLibrary** associates files with Ecto schemas, inspired by Spatie's
Laravel Media Library: collections, storage backends, image conversions,
responsive images, uploads, and LiveView components.

It is a **Phoenix library, not an application**. It is tied to Ecto (a
polymorphic `media` table, `has_many` associations injected into the host's
schemas) and ships LiveView components (`MediaLive`, `<.media_upload>`,
`<.media_gallery>`, image components) and a Plug (`Plug.MediaDownload`).
It has no endpoint, router, layouts, auth, or asset bundle of its own.

- **Stack**: Elixir, Ecto, Phoenix LiveView, Plug
- **Optional deps**: `:image` (libvips), `ex_aws_s3`, `oban`, FFmpeg on `$PATH`
- **Testing**: ExUnit against PostgreSQL (`Ecto.Adapters.SQL.Sandbox`)
- **Release**: Hex package (`mix hex.build`), no CI

## Skills

All skills live under `.agents/skills/`. Load the `SKILL.md` for a skill before using it.

### Five Non-Negotiables (always active)

1. **Surface assumptions before building.** State what you are assuming and ask for correction before writing any code.
2. **Stop and ask when requirements conflict.** Name the specific conflict; do not guess or silently pick one interpretation.
3. **Push back when warranted.** You are not a yes-machine. State the problem clearly, propose an alternative, then respect the final decision.
4. **Prefer the boring, obvious solution.** A staff engineer should see the code and say "of course." Cleverness is expensive.
5. **Touch only what you are asked to touch.** No unsolicited refactors, no "while I'm here" scope creep, no removing things you don't fully understand.

### Skill Route Map

> Load `using-agent-skills` first if unsure which skill applies — it acts as the meta-skill router.

| Situation | Skill to load |
|-----------|--------------|
| Starting any session or unsure which skill to activate — meta-skill router | `.agents/skills/using-agent-skills/SKILL.md` |
| The ask is underspecified — need to extract what the user actually wants | `.agents/skills/interview-me/SKILL.md` |
| Rough concept needs sharpening before writing a spec | `.agents/skills/idea-refine/SKILL.md` |
| Starting a new feature or significant change where no spec exists yet | `.agents/skills/spec-driven-development/SKILL.md` |
| Spec or requirements are clear — break work into ordered tasks | `.agents/skills/planning-and-task-breakdown/SKILL.md` |
| Need to load the right context for the agent at the right time | `.agents/skills/context-engineering/SKILL.md` |
| Need doc-verified, source-cited code for a framework or library | `.agents/skills/source-driven-development/SKILL.md` |
| Stakes are high or working in unfamiliar code — adversarial review of decisions | `.agents/skills/doubt-driven-development/SKILL.md` |
| Implementing any feature or change that touches more than one file | `.agents/skills/incremental-implementation/SKILL.md` |
| Implementing logic, fixing a bug, or changing behaviour — write failing test first | `.agents/skills/test-driven-development/SKILL.md` |
| Building or modifying the shipped LiveView components | `.agents/skills/frontend-ui-engineering/SKILL.md` |
| Designing the default look of shipped components (adapt React parts to HEEx/LiveView) | `.agents/skills/taste-skill/SKILL.md` |
| Designing a public function, behaviour, or module boundary | `.agents/skills/api-and-interface-design/SKILL.md` |
| Building or debugging anything that runs in the browser | `.agents/skills/browser-testing-with-devtools/SKILL.md` |
| Tests fail, builds break, or behaviour doesn't match expectations | `.agents/skills/debugging-and-error-recovery/SKILL.md` |
| Reviewing code before merging — correctness, readability, architecture, security, performance | `.agents/skills/code-review-and-quality/SKILL.md` |
| Code works but is harder to read or maintain than it should be | `.agents/skills/code-simplification/SKILL.md` |
| Handling uploads, remote URLs, filenames, signed URLs, or any untrusted data | `.agents/skills/security-and-hardening/SKILL.md` |
| Performance requirements exist or you suspect regressions | `.agents/skills/performance-optimization/SKILL.md` |
| Making any code change — commit hygiene, branching, versioning | `.agents/skills/git-workflow-and-versioning/SKILL.md` |
| Setting up or modifying CI/CD pipelines (this project has none by decision, ADR-022) | `.agents/skills/ci-cd-and-automation/SKILL.md` |
| Removing old code, migrating users, or sunsetting features | `.agents/skills/deprecation-and-migration/SKILL.md` |
| Making architectural decisions or recording context for future engineers | `.agents/skills/documentation-and-adrs/SKILL.md` |
| Preparing a Hex release — checklists, versioning, rollback | `.agents/skills/shipping-and-launch/SKILL.md` |
| Writing or editing any prose (docs, READMEs, code comments, commit messages, ADRs): cut AI tells | `.agents/skills/unslop/SKILL.md` |

## Project Guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use `:req` (`Req`) for HTTP requests (e.g. downloading remote files); **avoid** `:httpoison`, `:tesla`, and `:httpc`
- **Never write a date or timestamp into any file without first checking the real current time** using the available tool. Do not assume or guess the date — clocks are cheap, wrong dates in committed files are permanent.
- Architecture decisions go in `docs/decisions/`, specs in `docs/specs/`, plans in `docs/plans/`, ideas in `docs/ideas/`, and what is planned but not yet specced in `docs/backlog.md`
- Every user-visible change gets a `CHANGELOG.md` entry under `[Unreleased]` until a release is cut
- **Versioning:** follow semantic versioning. Fixes and patches go into the current patch line (0.8.x); new features or changed behaviour go into the next minor (0.9.0). Ask before deciding which.
- **No CI** (ADR-022). `mix precommit` is the only gate, so run it before every commit
- Commit in logical, vertical slices; each commit should compile and pass the tests on its own

## Key Files

| File | Purpose |
|------|---------|
| `AGENTS.md` | This file — agent instructions, skill routing, and coding rules |
| `CLAUDE.md` | Claude Code pointer → `@AGENTS.md` |
| `docs/decisions/` | Architecture Decision Records (ADRs) |
| `docs/specs/` | Feature specs |
| `docs/plans/` | Implementation plans (`00-milestones-1-4.md` is the pre-0.9 roadmap, archived) |
| `docs/ideas/` | Ideas and explorations |
| `docs/backlog.md` | Planned work without a spec yet, and the parking lot |
| `CHANGELOG.md` | Release notes (Keep a Changelog) |
| `guides/` | User guides published on HexDocs |

---

## Library design rules (deliberate — do not "fix")

These choices are intentional; do not refactor them away without being asked:

- **`MediaLive` is a `LiveComponent` on purpose.** The general advice to "avoid LiveComponents" does not apply: a self-contained, drop-in upload widget is exactly the strong, specific need that justifies one.
- **Never assume the host app's scaffolding.** Shipped components must not depend on `core_components` (`<.icon>`, `<.input>`), `Layouts`, `current_scope`, routes, or the host's `app.css`. They carry their own markup and accept `class` overrides.
- **Settings and processing live in one place** (ADR-014). Per-collection settings are resolved by `PhxMediaLibrary.Model`; each processing step is one function in `PhxMediaLibrary.Pipeline`. Uploads, mix tasks and the doctor call those; never re-implement a setting lookup or a step elsewhere.
- **The library chooses stored filenames** (ADR-015). Never store or build a path from the uploader's filename; it is kept in `metadata["original_file_name"]` for display.
- **Components scope client-supplied IDs to their own record** (ADR-018). Who may edit a record is the host app's decision, not the library's.
- **Dependencies stay optional and minimal.** Optional-dep modules are wrapped in `if Code.ensure_loaded?` (ADR-010). Never add a required dependency without explicit agreement.
- **Behaviours over hardcoding.** Storage, image processing, video processing, async processing, MIME detection, metadata extraction and path generation are behaviours with shipped defaults. New capabilities are new adapters.

### Library design principles

- **Provide sensible defaults** but allow configuration at every level
- **Avoid global configuration** where possible. Prefer passing options explicitly or using schema-level configuration
- **Use behaviours** for extensibility (storage adapters, image processors, etc.)
- **Keep dependencies minimal**. Make heavy dependencies optional where feasible
- **Document the public API**. Every public function needs `@doc` and `@spec`
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

---

## Technical Coding Rules

These rules are always active. They govern how code is written in this repository.

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
- Run `mix dialyzer` to catch type errors

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
- Tests that change application env **must** restore it exactly, including "not set" (`Application.fetch_env/2` before, `delete_env/2` after when it was unset)
- The library's own `config/config.exs` differs from an app's defaults; cover default behaviour with tests that run without that config

### Library-specific testing

- **Test with real files** in a temporary directory that gets cleaned up after each test
- Use `tmp_dir` ExUnit tag or create fixtures in `test/support/fixtures/`
- **Test all storage adapters** with the same test suite using adapter-agnostic assertions
- Write integration tests that verify the full flow (add media → store → retrieve → convert)
- Use mocks sparingly. Prefer testing against real implementations or in-memory adapters
- **Always** test error conditions and edge cases (missing files, invalid formats, storage failures)

## Ecto guidelines

- **Always** preload Ecto associations in queries when they'll be accessed together
- `Ecto.Schema` fields always use the `:string` type, even for `:text` columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such an option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
- Remember `import Ecto.Query` where you build queries

### Media library Ecto patterns

- Design the media schema to be **polymorphic**. It associates with any user schema via `belongs_to :mediable, ..., polymorphic: true` or a similar pattern
- Store file metadata (size, mime type, dimensions) in the database for querying
- Use **JSON columns** for flexible metadata storage (custom properties, responsive image data)
- Provide migration generators for users to create the media table in their apps
- Consider soft deletes for media records to allow recovery

## File and storage guidelines

- **Abstract storage behind behaviours** to support local filesystem, S3, GCS, etc.
- **Never** trust user-provided filenames. Sanitize or generate safe names
- Store files with **unique names** (UUIDs or hashes) to avoid collisions
- Preserve original filename in database metadata, not in the stored path
- **Calculate and store checksums** (MD5/SHA256) for integrity verification
- Support **streaming uploads** for large files to avoid memory issues
- Handle **mime type detection** properly. Don't rely on file extensions alone

### Path conventions

- Use a consistent, predictable path structure: `{collection}/{id}/{conversion}/{filename}`
- Make paths configurable but provide sensible defaults
- Support both public and private file URLs
- Generate **signed/expiring URLs** for private storage backends

## Image processing guidelines

- **Make image processing optional**. Don't require ImageMagick or libvips for basic usage
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

---

## Phoenix guidelines

The rules below apply to the components and Plug this library ships. Rules
about an application's scaffolding (`Layouts`, `current_scope`,
`phx.gen.auth`, router scopes, `<.flash_group>`, the `app.css`/`app.js`
asset pipeline) do not apply: the library has none of those and must not
assume the host app's.

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
- **Never** write inline `<script>custom js</script>` tags within templates; use colocated hooks (below)

## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>

## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponents** unless you have a strong, specific need for them (`MediaLive` is one, see the design rules above)

### Shipped component styling

- Components ship Tailwind classes in their own markup, never in external CSS, so the host app can override every class
- Every component accepts `class` (and slots where layout varies) for full override; defaults should look good without customization and support `dark:` variants

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @stream.tasks} id={id}>
          {task.name}
        </div>
      </div>

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items along with the updated assign

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised
- A library cannot add hooks to the host app's `app.js`, so shipped components use **colocated hooks only**:

      <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
      <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
        export default {
          mounted() {
            this.el.addEventListener("input", e => {
              let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
              if(match) {
                this.el.value = `${match[1]}-${match[2]}-${match[3]}`
              }
            })
          }
        }
      </script>

- colocated hooks are automatically integrated into the host's app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`
- Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle. **Always** return or rebind the socket on `push_event/3` when pushing events:

      socket = push_event(socket, "my_event", %{...})

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Function components are rendered with `render_component/2` (import it from `Phoenix.LiveViewTest`)
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** test against raw HTML of a whole page, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements

### Form handling

- **Always** use a form assigned via `to_form/2` in the LiveView. `<.input>` belongs to the host app's `core_components`, so shipped components use plain inputs or `<.live_file_input>`:

      <%!-- ALWAYS do this (valid) --%>
      <.form for={@form} id="my-form">
        <input type="text" name={@form[:field].name} value={@form[:field].value} />
      </.form>

      <%!-- NEVER do this (invalid) --%>
      <.form for={@changeset} id="my-form">
        ...
      </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**
