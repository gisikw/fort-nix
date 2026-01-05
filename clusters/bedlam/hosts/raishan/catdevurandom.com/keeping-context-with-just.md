---
title: "Keeping Context with Just"
date: 2025-05-01
slug: "local-justfiles"
summary: "A shell wrapper for Just that lets you maintain local task overrides alongside project Justfiles."
---

I find myself jumping between repositories a lot - whether dealing with scattered microservices at my day job, or riding the waves of inspiration and abandonment that comes from hobby projects. But when I find myself returning to these projects after a bit of an absence, I find myself struggling to remember the particular incantations needed to get this _particular_ project working.

There are lots of tools that help couple your environment to your codebase, which is wonderful. Mise or asdf or nvm/rvm/pyenv for high level tooling switcheroos. `.env` or `.envrc` files for carrying around local configuration. Nix shell or Docker for spinning up dependent services, or even providing a sandbox within which to work. It's all great and wonderful and amazing.

> Right, but...which one are we using here?

Task runners solve for this a little bit. Make everything a `mix` task in your Elixir project, and you can just list them all out. Substitute `cargo`,  `rake` or `npm run` or Procfiles or jumbled bash scripts to taste. Pick something that matches the language of the majority of your tasks, and shell out from within that code for the rest. But again, it's not going to be consistent from project to project, and the friction of remembering "this one uses a gulpfile" can be really frustrating. The closest to something language/framework-agnostic we have is `make`, but it's a bit arcane, and was originally intended as a build tool rather than a task runner.

## Enter Just

I've settled on [Just](https://github.com/casey/just) as my command runner of choice. It's fast; it's easy to install; it's a binary - so you don't need your JS or Ruby or whatever runtime available. It's `make`-inspired, but a bit more modernized.

```
just deploy
```

I encourage you to read through the README for more hype - there's a lot to love. But there's one important gap that Just _doesn't_ provide that I need to solve for.

## Smuggling in your secret recipes

If you're the author of a repo, by all means, throw stuff in a Justfile and walk away happy. But often, you may have your own custom stuff that you'd like to keep in the repo but wouldn't be appropriate to commit to the project in full.

> Create a user with my email and password 'password', do that weird user activation token step automatically, and seed it with five records. Oh, and configure this custom flag because I need that in order to get the thingamabob to work...

**Just** runs off a single Justfile. That file can import dependencies, but right now we can't `just --justfile=Justfile --justfile=mycustomtasks.just`

Thankfully, that's nothing a little bash can't solve for us! Within our `.bashrc` or `.zshrc`, or some file sourced therein, we can write our own `just` wrapper.

```bash
just() {
  if [ -f ./local.just ]; then
    if command just --justfile ./local.just -n "$@" >/dev/null 2>&1; then
      command just --justfile ./local.just "$@"
    else
      command just "$@"
    fi
  else
    command just "$@"
  fi
}
```

A little hard to read, but let's break it down. If a `local.just` file exists in our current directory, we run:

```
command just --justfile ./local.just -n "$@"
```

`command` is a way to ensure we don't recursively call our function, since our alias has the same name as the underlying binary. We're passing the justfile explicitly, and then using the `-n` flag to instruct Just to treat this as a dry-run. Why do this? This way we check if the `local.just` _would_ do anything with the args (`"$@"`) we've passed in. If we're calling `just deploy`, which is a task defined in the project's `justfile`, we likely don't have our own custom version.

If the dry-run succeeds, we'll run it for real. If not, we'll defer to the main `justfile`.

Now we can have a `justfile` and a `local.just` file living side-by-side, and we can execute `just fix-my-local-branch` from our custom tasks, while preserving access to project-level tasks that may already exist.

Don't forget to add `local.just` to your `~/.config/git/ignore` or `~/.gitignore`, and you'll never have to worry about accidentally slipping it into your projects.

## But what can we actually do?

Last task is making sure we can actually remember what affordances we have in our repo. `just -l` will list out the available tasks, but that doesn't quite work for us, since we're splitting our tasks across two different files. That's where we can leverage tempfiles. First, let's replicate the logic for figuring out what `just` would default to as its default justfile:

```bash
function find_justfile() {
  dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/justfile" ]; then
      echo "$dir/justfile"
      return 0
    elif [ -f "$dir/Justfile" ]; then
      echo "$dir/Justfile"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}
```

We'll just walk up the tree looking for one until we find it or give up (a more sophisticated solution might look at args, but this gets us 90% of the way there).

Then we can build a temporary combined file with all our tasks in it, solely for the purpose of reporting things out:

```bash
base_justfile="$(find_justfile)"
tmpfile="$(mktemp)"

[[ -n "$base_justfile" ]] && cat "$base_justfile" >> "$tmpfile"
[[ -f ./local.just ]] && cat ./local.just >> "$tmpfile"

if [ ! -s "$tmpfile" ]; then
  printf "\033[1m\033[31merror:\033[0m\033[1m No justfile found\033[0m\n" >&2
  rm "$tmpfile"
  return 1
fi

command just --justfile "$tmpfile" "$@"
rm "$tmpfile"
```

When we call `just --justfile /tmp/our-constructed-file -l`, we'll now get *all* the tasks. Our default justfile tasks *plus* our custom ones. And remember that `just` will show the comment from above your task in the list output. so you get a lovely readable...

```
❯ just -l
Available recipes:
    build # Build the local environment
    haaalp # Try that reset trick 🙏
```

It may not solve all the problems of hopping back and forth between repos, but a nice framework for saving out local aliases is at least a start to maintaining our sanity!

The full shell script (plus adding `local.just` to your global gitignore, and installing [Just](https://github.com/casey/just)):

```bash
function find_justfile() {
  dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/justfile" ]; then
      echo "$dir/justfile"
      return 0
    elif [ -f "$dir/Justfile" ]; then
      echo "$dir/Justfile"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

just() {
  if [[ " $* " == *" -l "* ]]; then
    base_justfile="$(find_justfile)"
    tmpfile="$(mktemp)"

    [[ -n "$base_justfile" ]] && cat "$base_justfile" >> "$tmpfile"
    [[ -f ./local.just ]] && cat ./local.just >> "$tmpfile"

    if [ ! -s "$tmpfile" ]; then
      printf "\033[1m\033[31merror:\033[0m\033[1m No justfile found\033[0m\n" >&2
      rm "$tmpfile"
      return 1
    fi

    command just --justfile "$tmpfile" "$@"
    rm "$tmpfile"
  else
    if [ -f ./local.just ]; then
      if command just --justfile ./local.just -n "$@" >/dev/null 2>&1; then
        command just --justfile ./local.just "$@"
      else
        command just "$@"
      fi
    else
      command just "$@"
    fi
  fi
}
```