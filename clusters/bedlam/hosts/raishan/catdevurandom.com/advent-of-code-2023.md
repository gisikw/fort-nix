---
title: "Advent of Code 2023: 28 Languages in As Many Days"
date: 2024-01-04
slug: "advent-of-code-2023"
summary: "A journey through 28 programming languages while solving Advent of Code 2023, with impressions and takeaways from each language."
---

Last year was my first experience with Advent of Code, when I tried to solve each day using Bash and Unix tools. This time around, I wanted to try a new language each day. This post is meant to share my experience across a variety of languages, along with some general takeaways.

## Making Preparations

The general pattern for Advent of Code problems is to take an input file, do some parsing of its contents, and output a scalar value. Once the first part of the problem is solved, there's generally a twist on the original problem, and we need to perform a new operation against the same input.

With that in mind, I created an `aoc` wrapper that runs a language-appropriate command within a Docker container, such that we supply the `$inputFile` and the `$part` of the problem, and expect the answer to be returned as the last line of STDOUT. Standardizing this format means we can do some fun stuff like save example inputs/outputs, submit the answer automatically, cache the MD5 of the correct answers, etc. Feel free to [peruse the repo](https://github.com/gisikw/advent-of-code) if this sort of thing tickles your fancy.

Importantly though, this meant that for each language, we started off with a basic template that would count the lines of the input file and write that to STDOUT. Here's the reference bash implementation:

```bash
input_file=$1
part=$2

lines_count=$(cat $input_file | wc -l)

echo "Received $lines_count lines of input for part $part"
```

For each language, I had ChatGPT generate an equivalent to our starter template - this way we could confirm the containerized environment was adequately set up for our languages, and we wouldn't spend precious Advent of Code time debugging environment issues. Speaking of ChatGPT though...

## Setting Up Some Rules

Everyone is going to have their own sense of what's fair for Advent of Code and what crosses the line. Here's the approach I took:
#### Before Solving
- No ChatGPT/Copilot/etc
- Unlimited searching around the language or particular algorithms
- Avoided posts on r/adventofcode that had spoiler tags
- Standard libs that ship with the language are fair game

*There were a few cases this year where visualizations on the subreddit did provide useful nudges, so I'd probably recommend staying away from subreddit entirely if you want to feel that you solved things entirely on your own.*
#### After Solving / Giving Up
For days 21 and 24, I hit a wall without hints. So after spending enough time to admit to myself I was "giving up". In those cases though, I still wanted to go through the exercise of writing a solution for my input, so looking at hints felt like a valuable thing to do. As long as you're not using these things to get on the leaderboard, I think it's valid.

In any case, once I'd gotten a solution, I absolutely leveraged ChatGPT to help revise my code, identify areas where I'd deviated from best practices for the language, etc. Given I was looking at many languages I had minimal familiarity with, I just don't know what I don't know. Shy of being able to get a code review from someone who spends their days in each language, having the LLM critique me was the next best thing.
## Day One: Number Parsing

Given that the days ramp up in difficulty, I decided to start with an esoteric language: Shakespeare Programming Language. As the name suggests, the language seeks to make programs read like a Shakespeare play. Mostly this involves characters (who serve as variables and stacks) praising, insulting, and interrogating each other in order to set values and determining branching logic. For example, we can look at this excerpt from my solution:

```spl
Scene II: A digit first glimpsed.

Ophelia:
  Thou art a wolf.

Hamlet:
  Open your mind. 
  Am I as fair as you?
  If so, let us proceed to scene V.

Ophelia:
  Thou art twice the sum of a charming fine handsome noble hero and a warm loving happy King.

Hamlet:
  Am I more peaceful than you? If so, let us return to scene II.

Ophelia:
  Thou art the sum of thyself and the sum of a good sunny fair morning and the sky.

Hamlet:
  Am I more cowardly than you? If so, let us return to scene II.
  Remember thyself.
  ```

Nouns in the language are worth 1 or -1, according to whether they're "positive" or "negative" things, as subjectively determined by the language designers. These values are multiplied by two for every preceding adjective. So `wolf` is -1, but `cowardly wolf` is -2, and so forth. `Open your mind` is an instruction that reads a byte from STDIN. Finally, when a character is instructed to "remember" something, we push a value onto their stack to be retrieved later. With these in mind, we can interpret this code as:

```
LABEL: Scene 2
Hamlet <- -1
Ophelia <- read(STDIN)
if Hamlet == Ophelia: GOTO Scene 5
Hamlet <- 2*(16+8) # 48
if Hamlet < Ophelia: GOTO Scene 2
Hamlet <- Hamlet+(8+1) # 57
if Hamlet > Ophelia: GOTO Scene 2
Ophelia.push(Ophelia)
```

This way, we can loop over the input stream until we find the first byte whose ASCII value is between 48 and 57 - a digit. If we hit the end of the stream (-1) we jump to scene 5.

Since part 1 is all about extracting digits from these lines of input, solving this problem is fairly straightforward, if a bit...wordy.
### Part Two

While I was hopeful I could stick with SPL for the entirety of day one, the prospect of matching "e", "i", "g", "h", "t", along with all the other digits, would have been a lot of painful stack manipulation. So I opted for Ruby instead.

The only tricky bit here is that most Regexp implementations, even when using a global flag, will not find overlapping matches. For example, if we try to match two digits in a four digit string, we'll get two results, rather than the three we might expect:

```
"1234".scan(/\d{2}/) #=> "12", "34", but not "23"
```

I will admit that I was a bit irked to struggle with this on the first day, especially given that we didn't run into adversarial examples in the test input. But it was good to learn about that regexp behavior at least!

**Day 1, Part 1:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/01/spl/solution.spl)  
**Day 2, Part 2:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/01/ruby/solution.rb)  
**Problem Difficulty:** ⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️  
#### Shakespeare Programming Language
**Language Experience:** None    
**Language Difficulty:** ⭐️⭐️⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️⭐️  
#### Ruby
**Language Experience:** High    
**Language Difficulty:** ⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  

## Day Two: A Series of Cubes

Day two was all about determining properties of a set of colored cubes based on a random sample. The problem itself was not particularly complex, but it was a good opportunity to dust off the ol' lisp brain with Racket.

Reaching for regular expressions tends to be my go-to strategy for parsing up until the point where it stops working. And I took the same initial approach to extracting the numbers from the input strings "Game 1: 3 blue, 4 red; 1 red, 2 green, 6 blue; 2 green". It did work, but it didn't really leverage the pattern-matching I could have.

This is where leveraging ChatGPT was actually quite helpful for me. I avoided using an LLM before having submitted my solution, but once I'd gotten something working, I got a lot of enjoyment out of prompting the LLM.

> Hiya! I just solved an Advent of Code problem using Racket, which I don't have a ton of experience with. Can you review the following code and highlight some areas that might benefit from refactoring to make things more idiomatic?

Over the course of Advent of Code, variations on this prompt were incredibly helpful for identifying language features and design patterns specific to the language that I was working with. But staying away from any AI solutions until I'd solved things myself meant that I was able to understand any suggestions made, since I already had wrapped my head around the particular problem domain.

**Day 2:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/02/racket/solution.rkt)  
**Problem Difficulty:** ⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️  
#### Racket
**Language Experience:** Minimal    
**Language Difficulty:** ⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️⭐️  

## Day Three: Grinding My Gears

I want to like Lua, I really do. And it genuinely seems that for many, it's the perfect embeddable blank canvas. It's not the 1-indexing, nor the half-regex pattern-matching. I just don't have my head wrapped around tables.

In this particular case, I needed a matrix, a set, and an array. Figuring out the nuances of managing and iterating over those was a real headache. I did eventually figure out when to be using ipairs vs pairs vs indices, but it's definitely out of my head now.

In all fairness, my pain points could likely have been abstracted away by encapsulating these data structures into modules with well-named methods. And Lua is deliberately sparse. But all in all, just a subjectively unpleasant experience.

**Day 3:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/03/lua/solution.lua)  
**Problem Difficulty:** ⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️  
#### Lua
**Language Experience:** Minimal    
**Language Difficulty:** ⭐️⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️  

## Day Four: A Headscratcher

This felt like a decent problem for Prolog, and if I didn't get to it now, I shudder to think about the difficulties using it later. Once you start thinking in Prolog, it's really fun to work in, but it takes a bit for your brain to flip.

For me, I think a challenge comes from thinking about the command-query separation principal from imperative programming. The idea is that when you call a function, it should either *do a thing*, or *return a thing*, but not both. This makes it easier to reason about a function in the abstract. When we extend this to functional programming, we just avoid ever *doing a thing*, and consider every function in Lisp to be a query about the passed-in arguments.

Contrast this with Prolog. If I write `square(2, x)`, I don't get a return value. Instead I'm adding a constraint on the variables that are passed in. `2` is already narrowly defined, but now `x` goes from being "anything" to only being "some value which can be passed into `square(2, x)` without blowing up the program". So we're almost mutating `x` here - at least, it's in a different state than it was before we called the predicate. And the fun part is that there's nothing implicit about that predicate (which feels like a function, but isn't) that requires it to operate on that argument. If we call `square(x, 2)`, we're similarly constraining `x`. Or `square(x, y)` constraints both arguments, without resolving either one to a definite value.

Our job then is to express enough constraints around our answer that it resolves into just one option. We start off with an initial focus on parsing the inputfile and using `assertz` to populate facts into our world. It's easier to reason about our program if we weren't dependent on `assertz` side-effects, and I was tempted to just transform the input file into rules, but it felt cleaner to do the parsing and population of rules dynamically. A really pleasant problem once you're in the right headspace.

**Day 4:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/04/prolog/solution.pl)  
**Problem Difficulty:** ⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️  
#### Prolog
**Language Experience:** Minimal    
**Language Difficulty:** ⭐️⭐️⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  

## Day Five: A Haskell for Great Good

Today's problem was a step up in difficulty, and I did find myself thinking at multiple points that perhaps I should have saved Prolog for today, rather than use it so early. Day five was focused around applying various transformations to data, and reflecting on the relationship between the inputs and outputs.

For me though, today was about exploring Haskell, which was a really pleasant language in which to program. As a Ruby developer, I chafe a bit at Python's indentation rules, which can feel cumbersome at times. In Haskell though, where everything was tiny functions anyway, it felt really clean. And the compiler errors were straightforward in helping me refactor things when I'd made an error.

The real joy though came from after I had a solution (albeit one that took about five hours to run for part 2). ChatGPT in suggesting some refactoring told me about the function application operator. Rather than write `foo (bar baz)`, we can use the dollar sign to implicitly group everything on the right hand side: `foo $ bar baz`. This elegant piece of syntactic sugar made me very happy in how I was able to refactor things.

I'm painfully aware that solving a single Advent of Code problem is going to mostly give me a sense for language flavor and won't truly give me a sense of what it's like to live in a language day-to-day. But of the functional languages I explored this year, Haskell was perhaps my favorite.

**Day 5:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/05/haskell/solution.hs)  
**Problem Difficulty:** ⭐️⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️  
#### Haskell
**Language Experience:** None    
**Language Difficulty:** ⭐️⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  
## Day Six: The Great Race!

Day six is a straightforward math problem, and it was time for me to depart from the land of functional languages to spend some time with C. Honestly, not a ton to share here. My background with C doesn't extend much beyond a data structures class from forever ago, but this problem was simple enough that I wasn't able to get caught up in segfaults and memory leaks.

The biggest challenge was just a lack of easy parsing tools (without linking in anything externally). But even reading character-by-character to get our integers wasn't anything to write home about. A nice easy day.

**Day 6:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/06/c/solution.c)  
**Problem Difficulty:** ⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️  
#### C
**Language Experience:** Minimal    
**Language Difficulty:** ⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️  

## Day Seven: Joker's Wild

I spend a bit of time trying to tackle day seven - a poker-hand-sorting puzzle - with SQL. I got decently far, but ultimately couldn't find a way to get `regexp_split_to_table` to split `"aabbc"` into `["aa", "bb", "c"]` (the problem being that lookahead expressions in Postgres patterns treat parentheses as non-capturing). I ran into this later with input parsing in R and Julia - there's generally an expectation that your data will have separator tokens.

I'd revisit SQL later, but after banging my head against a wall, I threw some JavaScript together, loaded up with lazy regex, and called it a day.

**Day 7:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/07/node/solution.js)  
**Problem Difficulty:** ⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️  
#### JavaScript
**Language Experience:** High    
**Language Difficulty:** ⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  

## Day Eight: Ghost Cycles

Day eight was one of those days where I really benefitted from having a year of Advent of Code under my belt. For part two, you have a problem which starts to look like heat-death-of-the-universe (or at least heat-death-of-your-laptop) levels of computation. In those cases, it's prudent to look for loops and see what can be simplified. I think the way this problem was constructed tipped its hand to that strategy, which I appreciate, as it helps prime folks to think about looping conditions ahead of more challenging problems where it may not be so obvious.

As far as my language of choice, we went back to functional programming - this time with Erlang. We weren't building something distributed or fault-tolerant, nor exploring the actor model, so today's answer is just "Yet another Lisp with slightly different syntax". As far as the aesthetics go, it's no Haskell.

One headache I did run into: if you run your Erlang code with `escript`, there isn't a clean global namespace for your functions to sit in. So `do_a_thing(data, fun my_helper_function/1)` will stubbornly insist that `my_helper_function/1` doesn't exist. This isn't a function hoisting issue, just something unique to the interpreter. So, opt to compile your Erlang and save yourself a headache.

**Day 8:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/08/erlang/solution.erl)  
**Problem Difficulty:** ⭐️⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️  
#### Erlang
**Language Experience:** None    
**Language Difficulty:** ⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️  

## Day Nine: Oh Camels!

Given that the storyline for day nine involves camels, it felt appropriate to reach for OCaml today. And OCaml features the lovely `|>` pipeline operator, which I first encountered in Elixir and was excited to see here. Not only that, but OCaml also has the function application operator that we saw in Haskell, though rather than `$` it's `@@` here.

As far as syntactic goodies go, OCaml is a winner for sure. Today's problem was straightforward enough though that I can't honestly say we put it through its paces. Still, definitely something to revisit!

**Day 9:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/09/ocaml/solution.ml)  
**Problem Difficulty:** ⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️  
#### OCaml
**Language Experience:** None    
**Language Difficulty:** ⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  

## Day Ten: Feeling Rusty

Back to systems languages, and it's time to look at Rust. I knew going into it that trying to understand the borrow checker was going to be a learning curve, but lifetimes came out of nowhere to smack me upside the head. The problem itself wasn't too difficult, just a bit intricate. Still, I have to confess there's a bug somewhere in my flood fill algorithm that I'm addressing with a `magic_offset_to_get_the_right_answer = 3;` variable in my code. Perhaps I'll go back and fix it at some point, but I just don't have the enthusiasm to wade back in.

Rust feels like one of those languages I *ought* to learn, and to be fair the compiler was very friendly in how it eviscerated my code. But I can't say I'm looking forward to revisiting it. Perhaps dedicating a full AoC year, from easy problems up to hard ones, would make for a good rampup.

**Day 10:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/10/rust/src/solution.rs)  
**Problem Difficulty:** ⭐️⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️  
#### Rust
**Language Experience:** Minimal    
**Language Difficulty:** ⭐️⭐️⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️  

## Day Eleven: Never Go Full Dijkstra

Okay, I was excited to do some pathfinding. So I reached for Dijkstra's algorithm without really considering whether it was necessary. Today's language was Crystal - which is supposed to be the compiled, fast, systems language that uses Ruby-style syntax. And to be fair, it is mostly Ruby with type annotations. There were a few times where I thought the type ought to be inferable, or at least that the language ought to support implicit casting, but it wasn't too bad.

```crystal
aBunchOfInt64s.reduce(:+) # Nope, this is too Ruby
aBunchOfInt64s.reduce(0) { |acc, n| acc + n } # Can't add i32 and i64
aBunchOfInt64s.reduce(0.to_i64) { |acc, n| acc + n }
```

Did a rewrite without Dijkstra, which was faster. Interestingly, something about containerization didn't play nicely with Crystal. The runtime for the solution was around 45s on my host machine, but takes nearly eight minutes within a Docker container. Admittedly I'm running on Apple Silicon, and many of the images are amd64, so there's some overhead there, but this warrants some further investigation down the line.

Overall, consider me whelmed. Even on the host machine it wasn't so blazing fast as to impress, so I'm not sure where the happy medium lies of problems that are too slow in Ruby, but don't need to be too speedy either.

**Day 11:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/11/crystal/solution.cr)  
**Problem Difficulty:** ⭐️⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️  
#### Crystal
**Language Experience:** Minimal    
**Language Difficulty:** ⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️  
## Day Twelve: Speaking of Ruby...

On the subject of Ruby, but X...how about Ruby, but a Lisp? It was time to reach for Elixir, which I think does have a reputation as being pretty friendly as functional languages go. Built on top of Erlang, but sporting our friend the `|>` pipeline operator. Easy process spawning, guard clauses, all the comforts you might want from your functional language. I'm a big fan of the function overloading with pattern-matching:

```elixir
# "Presenter" method without some tail-call arg
def sum(list), do: sum(list, 0)

# Base case
def sum([], answer), do: answer

def sum([n | rest], answer) do
  sum(rest, answer + n)
end
```

It feels easier to reason about the different cases as separate functions, rather than define some megafunction with a bunch of match conditions. Though it's worth mentioning that this is a feature shared by both Haskell and Erlang, so options abound.

Day twelve was a dynamic programming problem, and I'll admit I spent way too much time thinking "these two branches of the search space are the same. How can I collapse them and multiply the value by the number of duplicates". When memoization finally raised its head, it was embarrassing how effective it was.

**Day 12:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/12/elixir/solution.exs)  
**Problem Difficulty:** ⭐️⭐️⭐️⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  
#### Elixir
**Language Experience:** Modest    
**Language Difficulty:** ⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  

## Day Thirteen: Tiny Cool Language

This was a fun problem, and I decided to use Tcl to solve it. There are some particulars about Tcl, but I'd be thrilled to see Tcl take over Lua as the "tiny little embeddable" niche language. It also also made me wonder why we have Bash scripts. Just one of those languages that's been sitting there and I haven't taken the time to look at. Good to check it off my list.

**Day 13:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/13/tcl/solution.tcl)  
**Problem Difficulty:** ⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  
#### Tcl
**Language Experience:** None    
**Language Difficulty:** ⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  

## Day Fourteen: SQL and R

I'm proud of my solution today - via use of some clever substring string sorting, I was able to solve part 1 using SQL. We had to move elements around on a matrix, which is definitely not what SQL is intended for, but hey, sometimes you just want to go crazy.

When we got to part two, the prompt asked us "do this for 1000000000 cycles". And that was my cue to leave SQL land. We know we'll be looking for loops, rather than actually perform the operation a billion times, but even running our part 1 implementation a thousand times would be prohibitive. So it was time to explore R.

R, for its part was pleasant enough. Using `<-` for assignment feels unwieldy to me, but I suppose it's important to avoid scaring away the mathematicians. Joking aside, I suspect there would have been better days to leverage R for, and manipulating matrices of ASCII characters just isn't the puzzle to let this language shine.

**Day 14, Part 1:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/14/sql/solution.sql)  
**Day 14, Part 2:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/14/r/solution.R)  
**Problem Difficulty:** ⭐️⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️  
#### SQL
**Language Experience:** Medium    
**Language Difficulty:** ⭐️⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️  
#### R
**Language Experience:** None    
**Language Difficulty:** ⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️  

## Day Fifteen: Back to BASICs

I took a risk today because I knew I could solve part 1 using QBASIC. I was fully expecting part 2 to kick me out and have me reaching for another language, but was thrilled to see that wasn't the case!

To my surprise, there's been some evolution of BASIC syntax since my childhood. There are loops and blocks and functions and such. And nary a GOTO to be found. Needless to say I ignored all that, and stuck with GOTOs and LABELs for my solution. If I'm going on a nostalgia trip, I'm going all the way. This felt more like playing a Zachtronics game than writing software.

Can't really say this is a language has too much to recommend it these days, but it was so much fun to revisit, thinking back to being eight years old and typing in rudimentary implementations of hangman.

**Day 15:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/15/qbasic/solution.bas)  
**Problem Difficulty:** ⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  
#### QBASIC
**Language Experience:** Childhood    
**Language Difficulty:** ⭐️⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  

## Day Sixteen: Let's Go

Time to return to contemporary languages. I'll be honest, I got annoyed with Go for putting things in my home directory without permission, and never really spent much time with it after that (*Note: if you're starting to get the sense that my perspective on these languages is going to be superficial and idiosyncratic...trust your instincts*). But with Go safely isolated away in Docker Jail, we could focus on solving the problem.

Day sixteen wasn't particularly challenging, provided you had a strategy for managing split beams that avoided infinite loops. Props to Advent of Code for including a looping condition in the example, so there was no temptation to avoid handling it. Nothing remarkable to say about go, save for one complaint: compilation errors for unused variables.

I'm going to go on record and say this is developer-hostile design. Perhaps you write your code so perfectly as to never need to comment things out for testing. But the friction introduced by having to track which of your variables you happen not to use at the moment, and either comment them out or "pretend" to use them (`_ = iWillUseThisLater`) is frustrating - and it's friction that tends to arise when you're already dealing with debugging. Why kick me when I'm down, Go?

**Day 16:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/16/go/solution.go)  
**Problem Difficulty:** ⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  
#### Go
**Language Experience:** Minor    
**Language Difficulty:** ⭐️⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️  
## Day Seventeen: Full Dijkstra

Alrighty, it's proper pathfinding time! Moreover, it's pathfinding-with-a-twist time! I've been waiting for this, and saving an "easy" language for today. Best of all, Python has a priority queue implementation I can have, so I needn't build one like back when I was trying to solve day eleven in Crystal with Dijkstra.

The puzzle was straightforward enough once you baked the additional constraints into the landscape, though it took me a little bit of time to recognize that strategy - I think we're technically navigating four-dimensional space. I struggle sometimes with Python just because it's very similar to Ruby, which I learned first. Shout-out to the `partial` function, which made switching between parts 1 and 2 super trivial!

**Day 17:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/17/python/solution.py)  
**Problem Difficulty:** ⭐️⭐️⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  
#### Python
**Language Experience:** Minor    
**Language Difficulty:** ⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️⭐️  

## Day Eighteen: Tying the Shoes

The danger of asking AI to recommend a list of languages you should include in your catalog is that it's going to occasionally recommend something like D. The puzzle today was quite similar to day ten, but it was at a scale that makes using flood-fill the wrong approach. Instead, you'll want to opt for a mathematical approach for the area of a simple polygon that has integer vertex coordinates.

But I was still trying to brute force-things initially, and just trying to add `push` and `pop` to a queue was very confusing. Searching found me more looking through forum discussions than documentation pages, which wasn't ideal. Still, once the problem was simplified, the code wound up fairly clean. And I do like `auto myVar` as a nice "you figure it out!" type instruction to the compiler - I think I may prefer it to optional type declarations, honestly, as it keeps things visually consistent.

I do like these puzzles that throw back to prior days - it's a really good way to reward folks who review their solution after-the-fact. You may be able to brute-force the simpler problems, but if you take the time to go back and refactor after that, it'll be fresh in your mind should the approach resurface.

**Day 18:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/18/d/solution.d)  
**Problem Difficulty:** ⭐️⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  
#### D
**Language Experience:** None    
**Language Difficulty:** ⭐️⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️  
## Day Nineteen: Parts and Perls

Perl has a bit of a "here by dragons!" reputation, and I've been curious whether that stems from the emphasis on regex (which I personally love, but I know many find unpleasant), or some other features of the language. My takeaway after today: it's not just the regexes.

I do suspect I could grow to enjoy writing Perl, but the need to extract args in functions (reminiscent of Bash) and Perl's bad habit of merging array vars together when I wasn't looking, lead to some headdesking while I worked things out. That said, I do really like the `$scalar` `@array` `%hash` symbols to easily differentiate things. And `my var` is delightfully cozy.

This may have been the wrong day to mess around with Perl though - looking through the problem, I had feared we were dealing with overlapping ranges, and was fully down the rabbit hole of looking at whitepapers with names like "on calculating the measure of a union of hyperrectangles". I eventually got a hint from the subreddit that I'd gone off the deep end, and that just by looking at the problem, we could rule out such complicated math. I blame the eggnog.

**Day 19:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/19/perl/solution.pl)  
**Problem Difficulty:** ⭐️⭐️⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️  
#### Perl
**Language Experience:** None    
**Language Difficulty:** ⭐️⭐️⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️  

## Day Twenty: VM on the JVM

I love these types of puzzles. "Here's the definition for a pretend computer. Please emulate it for a while." So okay, we've got various objects with various behaviors, passing messages back-n-forth...time for some OO goodness.

Java is Latin for "boilerplate", so there's a bunch there, but solving part one was quite fun. Part two though managed to spoil my excitement - the solution here depends on finding loops in parts of the input that are specific to the problem, and I'm not sure of a way to identify that structure automatically. It seems that many folks used visualization tools - for my part, I was doing manual tracing in the input file. And the result was a solution that did cycle detection based on that manual detective work. So, it wouldn't work for any general input, which feels unsatisfying. Ah well!

**Day 20:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/20/java/Main.java)  
**Problem Difficulty:** ⭐️⭐️⭐  
**Problem Enjoyment:** ⭐️⭐️⭐️  
#### Java
**Language Experience:** Minor    
**Language Difficulty:** ⭐️⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️  
## Day Twenty-One: Infinite Gardens

Today's another day which is heavily informed by the input - and this time the example input *isn't* solvable by the same strategy. I'll admit that this is one I relied heavily on the subreddit for help with after spending a bunch of time both at- and away-from-keyboard trying to come up with a solution. I had identified some of the patterns in the input, and had made some attempts to capitalize on them, but it was subreddit visualizations that finally made things click. Still don't feel like I really solved this one fair-and-square.

Julia was a nice enough language. In particular when inviting ChatGPT to make refactoring suggestions, it was nice to be able to trivially do matrix division to solve a pair of quadratic equations. First time learning about Cramer's rule, so nice to learn some math facts, and nice to learn it in the course of using a math-friendly language.

**Day 21:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/21/julia/solution.jl)  
**Problem Difficulty:** ⭐️⭐️⭐⭐⭐  
**Problem Enjoyment:** ⭐️⭐️  
#### Julia
**Language Experience:** None    
**Language Difficulty:** ⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️⭐  

## Day Twenty-Two: Jenga!

In reading today's puzzle, it was very clear this could be solved brute-forcedly. But without knowing part 2, there's always a fear that will expand to a scale where it's no longer feasible. Still, best to reach for a systems language, so we have the best shot if this gets computationally expensive. We'd used C, D, Rust, Go, Crystal...time to reach for Nim.

What a pleasant language! You've got C-style pointers *and* stack-scoped pointers for when you just don't need to get that complicated, dangit. Creating custom iterators was nice and easy. Nice block declarations for named `break`, and sequence utilities! `map` and `filter` and `fold`!

Let me be clear: I'm the wrong person to be evaluating systems languages. But this was a language that asked me whether I wanted to *opt in* to memory management hell, with a full recognition that it's not the general case. I'm a fan.

**Day 22:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/22/nim/solution.nim)  
**Problem Difficulty:** ⭐️⭐⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️⭐️  
#### Nim
**Language Experience:** None    
**Language Difficulty:** ⭐️⭐️    
**Language Enjoyment:** ⭐️⭐️⭐️⭐️⭐  

## Day Twenty-Three: Dijkstra-Destroyer

Just to be clear: you can't do longest path with Dijkstra. But as long as you don't try to do that, this puzzle isn't too bad. I'd spent enough time in procedural languages though that shifting back to the functional paradigm was a little rough. This time, I went with Clojure, and discovered to my dismay that Clojure isn't tail-call-optimized. Apparently, this is due to limitations of the JVM, and there is a `recur` command that will jump to the top of the current function with new argument values to provide similar behavior, but you can't bounce back and forth between different functions trivially.

I learned the a bit late, and had to do a fair bit of refactoring, but eventually got it done. Not sure "it runs on the JVM" is a selling point for me, so probably put this beneath most of the functional languages I've messed with.

**Day 23:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/23/clojure/solution.clj)  
**Problem Difficulty:** ⭐️⭐⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️⭐️  
#### Clojure
**Language Experience:** None    
**Language Difficulty:** ⭐️⭐️⭐️    
**Language Enjoyment:** ⭐️⭐  
## Day Twenty-Four: Linear Algebra Ruins My Life

This was days and days of work. Part 1 was straightforward enough - had actually encountered matrix division as a mechanism for solving linear equations on day twenty-one! Part two though…

This really needed a linear algebra background or fluency with matrices that I just lack (the extent of by background with matrices is doing vector transforms for ray-tracing, but treating them as this scary black box). But I suspect there are some identities in there…maybe…no??

So okay, can’t solve this algebraically, let’s do it iteratively. Maybe we can iterate over various velocities, determine our nearest flyby, set our starting coordinates such that it *would* have been a collision, and then we can verify collisions with the remainder of the set. But that doesn’t work, because we’re sensitive to initial conditions here, and using an arbitrary initial position throws off the time step of the flyby, thus none of your candidate trajectories work (input data could have been friendly here, but alas)

So okay, not algebraically, nor iteratively, this sounds like a job for gradient descent!!! Write up a fitness function and start out with some exponentially reducing step sizes as a proof of concept aaaaand…no, the landscape is riddled with local optima so this is a complete no-go without some serious random restart / annealing / what have you.

So, after two days, I gave up. Wasn’t gonna solve it on my own, so let’s open up ChatGPT and the subreddit and at least have the experience of coding up a solution. Turns out that you can indeed express this as a set of linear equations, which you can reduce with Gaussian elimination. Man, between inventing photoshop blur and these math identities, that guy was busy. 

“a matrix can always be transformed into an upper triangular matrix, and in fact one that is in row echelon form”. Do those words mean anything to you? They didn’t to me, which resulted in a lot of ELI5 conversations with ChatGPT in which I had to repeatedly instruct it to define its terms. It retorted that I should consider taking a Coursera course.

Armed with that knowledge now, it was time to implement. Except…we’re multiplying big numbers. Like, really big ones. And we need exact outputs here. Big ints aren’t working because the intermediary values are getting truncated. Big floats are giving wildly different answers depending on which inputs we use, so the precision is an issue here. ChatGPT tells me that, alas, Zig doesn’t have a data type for rational numbers as part of their stdlib. So I guess I’m gonna need to build one.

Lots of caffeine later, I’m running data through as Rational structs, with add, subtract, multiply, divide all written out. And those big numbers are really big. Like, exceeding my i128 numerator/denominator big. So we add some gcd simplification. Aaand we still get overflow errors. So, we start recomputing gcds so that we can pre-divide terms before we multiply them to keep things low. And it’s still not enough.

So, we’re exceeding i128’s capacity with irreducible rational numbers. Clearly, we need BigNums. Or LazyEvalNums? Not super confident in my ability to write those from scratch. Let’s see what’s in the standard lib. Zig’s documentation is woefully poor, so let’s just search through the GitHub…

What’s this? A Rational implementation???

No docs, no Google search results, but it’s there! With like…two usage examples. So okay, let’s rig things up. At this point, I’ve used a reference implementation to figure out the answer I’m actually seeking, since my attempts seem to consistently get me within +/-500 of the actual answer. So I’m coding to the test, but I don’t care because the test is mean, especially for Christmas Eve when I was by all rights supposed to be assembling toys for the kiddos to destroy the next day. I’m having integer overflow nightmares in the middle of the night. My wife has left me for a Rust developer. The eggnog tastes like pointer dereferencing. Things are coming apart here.

Speaking of pointers, now we need to start passing allocators around because the Rational operators are all mutating functions, so memory is a fun puzzle. Also, turns out Zig wants you to deference pointers `likeThis.*` rather than `*likeThis`. The more you know!

Get the answer back, and it’s wrong. It’s close, don’t get me wrong, but it’s also wrong. It also appears that their implementation of a Rational struct just ignores the fact that a denominator is negative. So (-1 / -1) when pulled back into a float or an int is -1. Charming. And if we look at the reduction/simplification for the same inputs in Ruby, Zig is slightly off. Not wildly, but just enough to annoy someone who needs the precision enough to have reached for a Rational struct in the first place. But I give up. Search for inputs that give us a correct enough answer, adding in a `NEVER_TOUCHING_ZIG_AGAIN = -1` adjustment constant, and shipped it up!

**Day 24:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/24/zig/solution.zig)  
**Problem Difficulty:** ⭐️⭐⭐️⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️  
#### Zig
**Language Experience:** None    
**Language Difficulty:** ⭐️⭐️⭐️⭐️    
**Language Enjoyment:** ⭐  

## Day Twenty-Five: The Final Network

Alrighty, the last day! Time to roll up my sleeves and...actually, you know what? Let's just throw this into Graphviz and get the answer visually.

*several days later*

Alright, let's see if we can get F# to tell us the answer we already know :) Since we already had the answer, I was off the hook to try this one without help. I leveraged AI, looked up the relevant algorithms, this was a learning experience rather than a competitive one. F# seemed to be a fairly decent language, and this problem benefited from being able to make updates to nested data structures without having to create a million copies - hence heavy use of .NET mutable data structures as opposed to the more traditional functional ones.

Like Clojure, this feels like a language really focused on bringing functional programming to folks who still want to use their favorite libraries in the ecosystem they're already familiar with, but hey, whatever sparks joy!

**Day 25:** [source code](https://github.com/gisikw/advent-of-code/blob/main/solutions/2023/25/fsharp/solution.fsx)  
**Problem Difficulty:** ⭐️⭐️  
**Problem Enjoyment:** ⭐️⭐️⭐️  
#### F&#35;
**Language Experience:** None    
**Language Difficulty:** ⭐️⭐️    
**Language Enjoyment:** ⭐⭐️⭐️  
# Subjective Comparison

Time to bring down all the subjective language enjoyment scores and figure out what I liked best.

I suspect I may annoy some folks based on how I categorized things, but I've tried to organize the languages into three groups: ones that primarily focus on functional programming paradigms, once that emphasize performance, and everything else. I should note that just about every language's splash page says "high level, dynamic, multi-paradigm, fast, developer-friendly programming language", so enjoy what you like!
### Functional Languages
| | |
| --- | --- |
| Haskell | ⭐️⭐️⭐️⭐️⭐️ |
| OCaml | ⭐️⭐️⭐️⭐️⭐️ |
| Elixir | ⭐️⭐️⭐️⭐️⭐️ |
| Racket | ⭐️⭐️⭐️⭐️ |
| Erlang | ⭐️⭐️⭐️ |
| F# | ⭐️⭐️⭐️ |
| Clojure | ⭐️⭐️ |

### Performance Languages
| | |
| --- | --- |
| Nim | ⭐️⭐️⭐️⭐️⭐️ |
| C | ⭐️⭐️⭐️ |
| Crystal | ⭐️⭐️⭐️ |
| Rust | ⭐️⭐️ |
| Go | ⭐️⭐️ |
| D | ⭐️⭐️ |
| Zig | ⭐️ |

### Everything Else
| | |
| --- | --- |
| Ruby | ⭐️⭐️⭐️⭐️⭐️ |
| Prolog | ⭐️⭐️⭐️⭐️⭐️ |
| JavaScript | ⭐️⭐️⭐️⭐️⭐️ |
| Tcl | ⭐️⭐️⭐️⭐️⭐️ |
| QBASIC | ⭐️⭐️⭐️⭐️⭐️ |
| Shakespeare | ⭐⭐️⭐️⭐️ |
| Python | ⭐️⭐️⭐️⭐️ |
| Julia | ⭐️⭐️⭐️⭐️ |
| Perl | ⭐️⭐️⭐️ |
| Java | ⭐️⭐️⭐️ |
| SQL | ⭐️⭐️⭐️ |
| R | ⭐️⭐️ |
| Lua | ⭐️⭐️ |

So I guess my takeaways are: system languages are bad (except for Nim), functional languages are great unless they're in the .NET or Java ecosystem, Shakespeare is better than Python, and consider QBASIC for your next project!

## Real Takeaways

I had a ton of fun this year trying to expose myself to more languages and get a real survey of what's out there. There are definitely some gaps in what I still want to explore ([Uiua](https://www.uiua.org/) seems wild, for one!) but it was really fun to survey things and start to build some initial impressions. I absolutely want to play with Haskell and OCaml more, would love to see Nim get some more attention (though I suspect I'm just going to have to bite the bullet and learn Rust one of these days), and I feel like I might start reaching for Perl or Tcl in places where I might have otherwise written some Bash scripts.

As for next year, I think I might benefit from taking on one language and sticking with it all the way through (my Bash scripts have become so much more robust since using it for AoC 2022). But I also want to work through the back-catalog; there are a lot of puzzles left to solve! 

I also want to put some more time into my Advent of Code infrastructure - rather than spinning a container up and down each time I execute, it'd be nice to keep it around, perhaps with a filewatcher. And I could specify REPLs for the languages that support it, and integrate with my vim and tmux envs to set up my working environment for each language...

If you haven't had the opportunity to solve some puzzles, would highly encourage you to head on over to [https://adventofcode.com/](https://adventofcode.com/) and take a look. Just solving the first couple days couldn't hurt. Right?