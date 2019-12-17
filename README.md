# Tayne

<img align="right" width="100" src="tayne.gif">

This is an experimental Ruby -> LLVM compiler. It's written in Ruby itself to make it easy to obtain Ruby's AST.
It can compile programs using a subset of the Ruby language. It also has first class support for [sorbet](https://sorbet.org/)
and requires the programmer to use it so all types can be annotated at compile time.

> Currently only a subset of Ruby and Sorbet are supported. This is only a learning exercise.

## Install

I'm using ruby 2.6.5 currently, but most modern rubies should work.

First clone [ruby-llvm](https://github.com/ruby-llvm/ruby-llvm). You'll need an edge version
as it has not been published to rubygems in a while. I'm using this commit: `ec14c20b4e732a7f0056866abb98cfdf0fce6141` at the time of writing.

```
git clone git@github.com:ruby-llvm/ruby-llvm.git
```

You'll also need LLVM-8 installed (or whatever version of llvm ruby-llvm is supporting).
You'll need it installed in a place where the ruby gem can find it. I had to do this
on my mac:

```
ln -s /usr/local/lib/llvm-8/lib/libLLVM-8.dylib /usr/local/lib/libLLVM-8.dylib
```

CD into the gem and build and install:

```
cd ruby-llvm
gem build ruby-llvm.gemspec
gem install ruby-llvm-8.0.0.gem
cd ..
```

Now you can clone this repo:

```
git clone git@github.com:bhelx/tayne.git
cd tayne
bundle install --binstubs
```

If all is well, you should be able to run an example.

## Usage

```
./bin/tayne run examples/hello_world.rb --debug
```

The `run` command compiles and runs the program with the JIT compiler.
And debug will print out the AST and LLVM IR (before and after optimizations)
for debugging purposes

To run in MRI, use `mri`.

```
./bin/tayne mri examples/hello_world.rb
```

To compile to native code, use `compile`:

```
./bin/tayne compile examples/hello_world.rb > hello_world.ll
# run `llc-8 hello_world.ll` # if you wish to see assembly code
gcc -O3 hello_world.ll -o ./hello
./hello
```

## Development

Recompile the "kernel"

```
llvm-as-8 kernel/kernel.ll
```

