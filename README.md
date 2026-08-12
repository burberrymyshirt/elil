# Elil

## NOTE
This language does not make sense to use for anything in the real world.
It depends on two runtimes, the language runtime itself, and the erlang vm.
It does not compile to native BEAM code (as of right now 👀)
It is probably very slow, but as mentioned, it is not meant for production use in any scenario, so I haven't done benchmarking.
It is also my first attempt at writing any language parser (not counting failed attempts at json parsing), hence the relatively slow progress, high commit rate and quite a bit of churn.
It also doesn't use best practices, as I have not thought that far into the making, and I have written very little elixir before stating this, and understood even less of what I was writing.

It is a pet project I am making for myself to get better at writing elixir and honing generalized problem solving skills. I am by no means an expert in anything related to designing languages or parsing or whatever. Just trying to have fun and learn along the way.
It is also a catalyst to try and force myself through uncomfortable problems that I don't nesecerily see clear solutions for, as I have been dealing with motivational/confidence issues when running into those sorts of scenarios.

I plan on using it for more pet projects in the future, in order to own more of the personal programs I use, and actually develop things that are not nesecerily reproducible by LLM's (until they start stealing it anyways¹).

The `todo.txt` file is a messy list of every notable thought I have had along the way so far, not counting the countless todo comments. It also includes a list of a few ideas I have for this language as the first actual programs to run on the interpreter, to test what it is capable of and what is still needed for it to become usable. As if right now, I am developing from the POV of contrived incomplete example files.

1. I am obviously aware of the license being used here, but still reserve the right to be a bit spiteful of massive corporations taking even more advantage of free work.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `elil` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:elil, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/lil2>.

