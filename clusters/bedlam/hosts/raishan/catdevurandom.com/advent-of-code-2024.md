---
title: "Advent of Code 2024: All New Languages"
date: 2024-12-28
slug: "advent-of-code-2024"
summary: "Continuing the tradition of solving Advent of Code with a new language each day, featuring LOLCODE, Uiua, and 23 other languages."
---

[Last year](/advent-of-code-2023/), I completed Advent of Code using a different language each day -- winding up with 28 in all, as I bailed out of a few between part 1 and part 2.

Since then, I've gone back and completed some prior years' puzzles. I knocked out 2015 in Ruby, then did 2017 in Rust. Next was Python for 2016, and I'd made a start at 2018 in Go. Forcing myself to stick to a language for a year's worth of puzzles was much more informative. A lot of perceived complexity with languages is really just a lack of familiarity - which is to say I wouldn't trust the experience of doing a single AoC puzzle in a language to give a fair impression.

With that in mind, for this year I'm giving the fresh batch of languages two initial impression scores: frustrating (😣) and fun (🥳), each out of five.

## Quick Infra & Rules

My Advent of Code [infrastructure](https://github.com/gisikw/advent-of-code) is set up with a bunch of language templates and Dockerfiles. Every solution must accept an inputfile and part argument, then spit out a solution as its last line of stdout. The templates for each language count the number of lines in the input file - this is enough for me to at least verify we have stdio, args, and file reading working beforehand - if we can't manage that with a language, it's probably not a language we want to be solving in.

As for the solutions themselves...
* No LLMs, LSP hints, etc
* Avoiding tips - generally staying off the subreddit until we're solved
* Searching for docs, specific algorithm refreshers, etc are fine

---

## Day One: Esoterica, lol

Last year, I got Shakespeare Programming Language out of the way early, because the puzzles increase in difficulty, so best to get the "weird for the sake of it" languages in the mix early. This year, I followed the same tradition with LOLCODE.

The language isn't too bad. You get your basic C-style syntax, just written in a somewhat challenging way. You even get arbitrary objects -- erm, excuse me -- `ITZ A BUKKIT`. I did have to write my own quicksort (`HOW IZ I KWIKING YR LIZT`), but this was a fun enough language to mess around with for a day.

`KTHXBAI`

**Day 1:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/01/lolcode/solution.lol)  
**Language:** [LOLCODE](http://www.lolcode.org/)  
**Frustration:** 😣  
**Fun:** 🥳🥳🥳

## Day Two: ⊟↯⍜⧈!

I stumbled across Uiua last year, and was scared off. This language comes from two legacies: that of Forth (stack-based programming), and APL (confusing glyphs instead of code programming).

Uiua hurt my head, but in a really fun way. For example, the following two lines grab the input filename from CLI args, reads the file, splits it into lines, splits those lines into words, and parses those words into numbers.

```
&fras ⊡ 1 &args
∵(□⋕◇⊜□⊸≠@ ) ⊜□⊸≠@\n
```

Mercifully, Uiua doesn't force you to memorize all your vim digraphs - you can write out the name of the operation, say `keep`, and Uiua will helpfully reformat it to `▽` .  And you can bind these processing sequences to names, which made it easier to organize the code (at the expense of a bit of code golf).

My biggest struggle here was in trying to translate logic like `list.map(el => doSomething(el, foo))`. There were many cases where the order of the argument mattered, and when you're continually pushing items from a list onto the stack, you also need to duplicate those secondary arguments. Brutal, but we got there in the end. And honestly, had a ton of fun doing it.

**Day 2:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/02/uiua/solution.ua)  
**Language:** [Uiua](https://www.uiua.org/)  
**Frustration:** 😣😣😣😣😣  
**Fun:** 🥳🥳🥳🥳🥳

## Day Three: Embeddeds

There's gonna be a bit of a theme this year around reaching for uncommon embedded languages, and that's really just that I'm trying to avoid repeating languages from last year, and that means we're reaching a little bit. Today, we explore Wren.

We're still in the part of Advent of Code where the puzzles are pretty forgiving. However, this puzzle called for regular expressions - and you know what you don't have when you pull an embeddable scripting language off the shelf? A regex library. So we had to roll our own token parsing instead, which is fun anyway.

The one other gap is a lack of robust runtime error handling - which was needed for attempting to parse numbers. Wren's recommendation is to run runtime-unsafe code within a Fiber (Wren's coroutines), and to call `error = fiber.try()`. However, it wasn't immediately clear how we'd get both the happy path `value = fiber.call()` return value while also safely handling the runtime issue, so instead we rolled our own `DIGITS = "1234567890"` and used string comparison to make life easy.

**Day 3:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/03/wren/solution.wren)  
**Language:** [Wren](https://wren.io/)  
**Frustration:** 😣😣  
**Fun:** 🥳🥳🥳

## Day Four: Blasts from the Past

COBOL felt like a fairly bureaucratic language - which is fair enough. Many of these older languages prefer that you declare your variables ahead of time, and I caught myself wanting to abuse variables I was "done" with to use as loop counters later. That in turn had me wanting to just name them something fairly generic - akin to just giving myself registers.

Another thing that I found interesting about these older languages (and I'm kinda grouping Pascal, Fortran, COBOL, and Ada all together - unfairly, no doubt) was that they all have very much evolved over time. There wasn't a sense that "except for the punch cards, I'm programming 60's style!"

It wasn't immediately intuitive how I might get at the command line arguments in COBOL. But it can read from standard in, so `(echo $input_file; echo $part) | ./solution` in our runner file solves for that challenge.

**Day 4:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/04/cobol/solution.cob)  
**Language:** [COBOL](https://www.ibm.com/topics/cobol)  
**Frustration:** 😣😣  
**Fun:** 🥳🥳🥳

## Day Five: Yet Another Scripting Language

Today's puzzle was solved with yet another scripting language, fittingly called Yet Another Scripting Language. This one is C-style and very straighforward. There are always a few challenges with these smaller languages that can send you stumbling through docs - or at worst, the underlying source code. With YASL, learning that `args` was globally available I believe took some snooping at their test cases. But a clean language and clean puzzle.

**Day 5:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/05/yasl/solution.yasl)  
**Language:** [YASL](https://yasl-lang.github.io/docs/)  
**Frustration:** 😣😣  
**Fun:** 🥳🥳

## Day Six: But *which* Fortran?

Boy, there are a lot of Fortrans. I opted to use Fortran 90, which being released in 1990 puts it roughly halfway between present day and 1957 when the language was created. I was delighted to find it a pretty pleasant experience - more friendly than COBOL for my use case at least. I had it in my head that the older languages would be easier with line-based processing, but had no issues with a grid problem here.

**Day 6:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/06/fortran/solution.f90)  
**Language:** [Fortran](https://fortran-lang.org/)  
**Frustration:** 😣  
**Fun:** 🥳🥳🥳

## Day Seven: But *which* LISP?

When many functional languages come up, I feel like I'm cheating. Haskell and Erlang have created their own cultures, but there are still a lot of languages that when you squint look straight out of [Structure and Interpretation of Computer Programs](https://en.wikipedia.org/wiki/Structure_and_Interpretation_of_Computer_Programs). Janet is one such example. So...wrote some LISP with a `.janet` file extension, and got this one wrapped up!

**Day 7:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/07/janet/solution.janet)  
**Language:** [Janet]([https://janet-lang.org](https://janet-lang.org/))  
**Frustration:** 😣  
**Fun:** 🥳🥳🥳

## Day Eight: Another Another Scripting Language

Another delve into small embeddable languages - back to C-style here with MiniScript. Big shout out to them for creating a one-pager [QuickRef](https://miniscript.org/files/MiniScript-QuickRef.pdf) PDF. I leaned fairly heavily on https://learnxinyminutes.com/ for several languages, but this was an even better resource.

**Day 8:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/08/miniscript/solution.ms)  
**Language:** [Miniscript]([https://miniscript.org](https://miniscript.org/))  
**Frustration:** 😣  
**Fun:** 🥳🥳🥳

## Day Nine: The Language, not the Triangle

This puzzle seemed pretty complex, but I found an approach that avoided doing any real shuffling, and just navigated a few pointers around. Pascal's rapidly approaching languages I'm more familiar with!

**Day 9:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/09/pascal/solution.pas)  
**Language:** [Pascal](https://en.wikipedia.org/wiki/Pascal_(programming_language))  
**Frustration:** 😣  
**Fun:** 🥳🥳🥳

## Day Ten: I got a Roc

There's an inherent challenge with this particular challenge - even though I'm not competing for the leaderboard, I still feel a certain pressure to get a problem solved, such that I can get to sleep and avoid snoozing through my alarm in the morning. In cases like Roc, it means I'm happy to just accept that I get the gist of a language, but don't have the room to breathe such that I entirely know what I'm doing. I'm not sure I 100% grok the `Task` model here, and I'm sure there are more things that differentiate the language, but my brain decided "Okay, this is Elixir, so let's write some Elixir".

Definitely a language worth exploring again later, with more time. And being able to rely on Nix to provision the whole thing was a nice touch!

On the puzzle side, there's something really soothing about these "walk in the woods on a snowy evening" kinds of puzzles.

**Day 10:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/10/roc/solution.roc)  
**Language:** [Roc]([https://www.roc-lang.org](https://www.roc-lang.org/))  
**Frustration:** 😣😣  
**Fun:** 🥳🥳🥳

## Day Eleven: Speaking of Elixir

I'm sensing a few themes with these "carrying the baton" new languages (as distinct from the mini embeddable ones)
* `fn`. We're too busy for this `function` nonsense.
* We love Maybe's (Option and Result)
* Pipe operators too!
* Big projects and dependencies are fine again???

I'm onboard with everything except the last one. I didn't immediately see a way to just have a Gleam script, as opposed to a project directory. And there wasn't a clean way to just read from a file, so I had to use a library. I would have thought `left-pad` had convinced new languages to just create robust standard libraries, but I guess other ecosystems don't have those same concerns. In all fairness, if I was fluent in Erlang, I'm sure I could have dropped down to that level and read the file that way. But I've got mixed feelings about "batteries-not-included but look at all these amazing batteries!" ecosystems.

**Day 11:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/11/gleam/src/solution.gleam)  
**Language:** [Gleam]([https://gleam.run](https://gleam.run/))  
**Frustration:** 😣😣😣  
**Fun:** 🥳🥳

## Day Twelve: Oooh, this is new!

I really loved Arturo's concision - here's a language brave enough to say "what if the pipe operator were represented by a pipe character?". I didn't quite get the hang of the use of square brackets to denote both blocks and arrays (I *think*, looking through the docs now, that there really *isn't* a distinction, and you simply use the `@` operator to convert a lazily-evaluated array / block into an eagerly evaluated array, but it confused me at the time). Had an enjoyable time here and would be excited to revisit this language down the road. There's something about the syntax that just feels really clean.

```
perimeter: $[coords][
  coords
    | map 'coord -> 4 - (size neighbors coord)
    | fold => add
]
```

**Day 12:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/12/arturo/solution.art)  
**Language:** [Arturo]([https://arturo-lang.io](https://arturo-lang.io/))  
**Frustration:** 😣  
**Fun:** 🥳🥳🥳🥳

## Day Thirteen: Regular expressions!

Between legacy languages, embedded languages, LISPs that prefer more direct parsing...this is the first I'm reaching for regular expressions. Also great to see a return of Cramer's Rule!

**Day 13:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/13/php/solution.php)  
**Language:** [PHP]([https://www.php.net](https://www.php.net/))  
**Frustration:** 😣  
**Fun:** 🥳🥳🥳

## Day Fourteen: Oh Christmas Tree...

As puzzles go, this was a really fun one. Didn't really enjoy Ada as a language though. Struggled to figure out the right way to initialize a 2d array, and decided to just leave it flattened. I'm sure with more time, would have gotten used to it. But this is the last of the legacy languages for this year.

**Day 14:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/14/ada/solution.adb)  
**Language:** [Ada]([https://ada-lang.io](https://ada-lang.io/))  
**Frustration:** 😣😣  
**Fun:** 🥳🥳

## Day Fifteen: Programming Done Right?

Odin claims "Programming Done Right" on its splash page, which is a provocative claim. A few superficial thoughts:

* I like `defer` - defining "on scope cleanup" behavior. This exists in Zig as well.
* I don't love Go-style errors-a-second-returns, especially since I can't discard them to a `_` var.
* I don't love global procedures like `append` for adding to dynamic arrays. I prefer things to be namespaced into modules, so I can always assume anything without a prefix is something I can find in the same file.

Superficial nitpicks here, but such is the nature of a brief visit with languages!

**Day 15:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/15/odin/solution.odin)  
**Language:** [Odin]([https://odin-lang.org](https://odin-lang.org/))  
**Frustration:** 😣  
**Fun:** 🥳🥳🥳

## Day Sixteen: A frustrating choice

Today I tried to use Borgo - a language I'd stumbled across on HackerNews - and paid for it with some headaches. The purported goal of the language is to provide Rust-like syntax, on top of Go. However, very little of the Go stdlib has type declarations to make it available to Borgo. I could have written my own, I suppose, but wasn't really looking to shore up the language as much as I was trying to solve Advent of Code.

The other annoyance came into play using Rust-style match expressions. Borgo wants branches to be `,`-terminated. It also wants branching to be exhaustive. It also wants the expressions to return the same thing - even if we're discarding the result. But since we don't have semicolons to specify "this isn't a return value", it means we need to return `()` explicitly ourselves to make the Rust-like Borgo syntax rules pass. However, then the generated Go code throws an error, because the result _is_ saved to a temporary value there, which annoys Go because you're not supposed to have unused variables. So we need to pepper some branches with `let _ = ()`, to make both layers happy enough to run the darned code.

I know there is a market for "Rust, but I don't want to understand lifetimes or the borrow checker", and maybe Borgo will be that some day, but wasn't the best experience basaed on where it's at today.

**Day 16:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/16/borgo/solution.brg)  
**Language:** [Borgo]([https://borgo-lang.github.io](https://borgo-lang.github.io/))  
**Frustration:** 😣😣😣😣  
**Fun:** 🥳

## Day Seventeen: Emulation!

I was thrilled to finally by doing an "emulate this instruction set" puzzle - something about those just scratch an itch for me. It took a bit to figure out an approach for part two, but felt really satisfying once I'd gotten it.

Lobster was a nice language - terse and just enough that it got out of the way. Definitely another one that goes on my list to revisit.

**Day 17:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/17/lobster/solution.lobster)  
**Language:** [Lobster](https://strlen.com/lobster/)  
**Frustration:** 😣  
**Fun:** 🥳🥳🥳🥳

## Day Eighteen: A Reprieve

With Day 17 being one of the more challenging, Day 18 took its foot off the gas a bit. Today I used V, which is a language that was embroiled in some controversy for overpromising features, as far as I understand. But for our use case, it was plenty. I am starting to wonder just how many times I'm going to be implementing pathfinding this year though.

**Day 18:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/18/v/solution.v)  
**Language:** [V]([https://vlang.io](https://vlang.io/))  
**Frustration:** 😣  
**Fun:** 🥳🥳🥳

## Day Nineteen: Cleaner Lua?

Moonscript tries to sand off the rougher edges of Lua syntax (`endfunction`? Who has time for that!). My struggles with Lua tend not to be around the syntax, and mostly around the table data structure, which Moonscript keeps. But this was another simple problem day, so our time here is brief!

**Day 19:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/19/moonscript/solution.moon)  
**Language:** [Moonscript](http://moonscript.org/)  
**Frustration:** 😣  
**Fun:** 🥳🥳

## Day Twenty: Not Ruby

I have the vague sense that Groovy was responsible for convincing Java developers that Ruby sucked, and convincing Ruby developers that Java sucked. The syntax didn't seem too bad for me though, though using `def` for variable declaration was a bit odd. Implemented Dijkstra again because I didn't look too closely at the input for part one. But it made part two pretty trivial to solve, so not too broken up about it!

**Day 20:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/20/groovy/solution.groovy)  
**Language:** [Groovy](https://groovy-lang.org/)  
**Frustration:** 😣  
**Fun:** 🥳🥳

## Day Twenty-One: The Hard One

Two challenges here: Io as a programming language is left-associative, which took some getting used to - it was a really cool language otherwise though! No keywords or globals? Sign me the heck up!

The more significant challenge was the problem itself though. I clued in pretty quickly that we could exclude any staircase-style paths, which cut down our branching factor, but then spent way too long trying to construct an expanded graph of the paths. I gave up and solved part one as a simple text expansion problem. For part two though, that's just not remotely feasible. I banged my head against a wall trying to reduce branching paths and add some memoization, to no avail. Finally, I went to the subreddit - not looking at answers, but just eager to figure out if my approach was wildly off, or if I just hadn't found the right optimization yet. I saw folks mentioning depth-first search, and got really confused; gave up on this one.

I returned to it after solving day 22. This hadn't felt like a search problem to me, and it took me a while to start thinking of it in those terms. But once I got there, the implementation was really straightforward. So on the third rewrite, managed to finally land the plane here.

Io was a really fun language to explore; though I think it requires a certain degree of discipline to handle well, lest it get unreadable. This is a particularly bad example:

```
cache at(node depth) atPut("#{node src}#{node dst}" interpolate, min)
```

**Day 21:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/21/io/solution.io)  
**Language:** [Io](https://iolanguage.org/)  
**Frustration:** 😣😣  
**Fun:** 🥳🥳🥳🥳

## Day Twenty-Two: Easing Up

I tackled this one while letting Day 22 sit on the back-burner. I was a little surprised that integer division by powers of two doesn't automatically get optimized into bit-shifting operations, but easy enough to do that myself. A straightforward puzzle with those sorts of optimizations in-mind.

As for Haxe...I dunno. Wrapping your code in a class and a `static public function main()` feels a bit quaint these days. But nothing especially stood out to me here. I think Haxe's selling point is more than it can cross-compile to a lot of different targets, which isn't a feature I needed here. So, I'm sure there's value, but just not for me.

**Day 22:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/22/haxe/Solution.hx)  
**Language:** [Haxe](https://haxe.org/)  
**Frustration:** 😣  
**Fun:** 🥳🥳

## Day Twenty-Three: The Mobile Languages

I'd been saving some of the more "conventional" languages for near the end, as I figured the problems would be maximally difficult. Again, I'll caveat that this is first impressions, but I found Kotlin a bit annoying.

In Advent of Code puzzles, you're going to do a lot with lists, sets, and dictionaries. And you're gonna want to know the various operations you can perform on those collections. Those affordances in Kotlin are broken up across a bunch of different interfaces. A MutableSet gets some of its behaviors from `MutableSet<E>`, some from `Set<E>`, some from `MutableCollection<E>`, which in turn derive their behaviors from further decompositions. That's all fine, but it makes reading the documentation a nightmare. I just want to know what I can do with this Set! I don't care where those things came from.

In all fairness, this would be trivially solved by using an LSP. Or if I were doing Kotlin on a regular basis, I could throw together a cheat sheet of the common methods that I need on these collections. But things are finely sliced enough here that it added friction, and left a bit of a sour taste.

I like the immutable-by-default though!

**Day 23:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/23/kotlin/solution.kt)  
**Language:** [Kotlin](https://kotlinlang.org/)  
**Frustration:** 😣😣😣  
**Fun:** 🥳🥳

## Day Twenty-Four:

Now it's time to pivot to the iOS side. Docs were confusing here too, sorry to say. I still don't know where the `.whitespacesAndNewlines` in `content.trimmingCharacters(in: .whitespacesAndNewlines)` came from. I suppose though that mobile-focused languages are the ones where you can be most certain folks are using more powerful IDEs, so if there is an environment where a dependency on an LSP and other tooling is appropriate, this is that domain.

The puzzle itself was fun! I was initially worried there'd be a lot of extraneous wires, but scanning through things one-by-one made it easy to identify which circuits were broken. I was reminded of Bach's Tocatta and Fugue - which was originally written to ensure every key of a pipe organ was used and tested. Similar here - just try everything and fix what breaks!

**Day 24:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/24/swift/solution.swift)  
**Language:** [Swift](https://www.swift.org/)  
**Frustration:** 😣😣😣  
**Fun:** 🥳🥳

## Day Twenty-Five: A Last Hurrah!

Scala's infrastructure gave me a bit of a headache here. But once I got it running, this was a nice and simple problem to wrap up the year.

**Day 25:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2024/25/scala/Solution.scala)  
**Language:** [Scala](https://www.scala-lang.org/)  
**Frustration:** 😣😣  
**Fun:** 🥳🥳

## Conclusions

This was a really fun year! Unlike 2023, I had to stretch a bit to find languages I hadn't yet leveraged, and they broke into a few categories:

* Mainstream languages I hadn't gotten to yet: PHP, Groovy, Kotlin, Swift, Scala
* Legacy languages: COBOL, Pascal, Fortran, Ada
* Embedded languages / DSLs: Wren, YASL, Janet, Miniscript, Moonscript
* Experimental languages: Uiua, Roc, Gleam, Arturo, Odin, Borgo, Lobster, V, Io, Haxe
* Esoteric: LOLCODE

Of that list, the ones that really stood out to me as interesting were Uiua, Arturo, Io, and Lobster - though I can't say I expect any of them to ever become mainstream (Gleam is probably the most likely on the list to achieve that distinction). 

Next year, should I keep this up - it'll be an interesting challenge. There are a few languages that stand out as candidates (Carbon, APL), but I think I may need to start splitting hairs in what I consider different languages - but hey, Scheme, Racket, and Common LISP are all wildly different, right? Right?

As usual, Advent of Code was a fantastic experience, and I highly encourage you to spend some time tackling those challenges yourself! For my part, I've still got a good amount of the back-catalog to work through, so I'm gonna get back to 2018 in Go, and see you in 2025!