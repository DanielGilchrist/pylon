require "spec"
require "ameba"
require "ameba/spec/support"
require "../../rules/layout/type_structure"

private def correct_until_stable(rule : Ameba::Rule::Base, code : String) : String
  loop do
    source = Ameba::Source.new(code, normalize: false)
    rule.catch(source)
    return code unless source.correct!

    code = source.code
  end
end

describe Ameba::Rule::Layout::TypeStructure do
  subject = Ameba::Rule::Layout::TypeStructure.new

  it "passes a type laid out in order" do
    expect_no_issues subject, <<-CRYSTAL
      module Pylon::Example
        extend self
        include Comparable(self)
        extend Enumerable(String)

        Log = ::Log.for(self)
        LIMIT = 64
        private SECRET = 1

        alias Name = String
        private alias Hidden = Int32

        @[Flags]
        enum Mode
          Read
          Write

          def self.parse(raw : String) : Mode
          end

          def label : String
          end
        end

        record Hit, path : String, mode : Mode
        record Miss, message : String

        struct Cursor
        end

        class Cache
        end

        module Helpers
        end

        annotation Marker
        end

        @@instances = 0
        @@named : Int32 = 1
        class_getter registry = [] of Name
        class_property? verbose = false

        macro included
        end

        macro define_step(name)
        end

        def self.new(raw : String) : self
        end

        def self.build(path : String) : Example | Miss
        end

        protected def self.reset : Nil
        end

        private def self.collect(paths : Array(String)) : Array(Hit)
        end

        @cursor : Cursor
        @cache : Cache?

        def initialize(@path : String, @mode : Mode)
        end

        def finalize
        end

        @[JSON::Field(key: "p")]
        getter path : String
        getter? dirty : Bool
        property mode : Mode
        setter owner : String
        delegate size, to: @cache
        def_equals_and_hash @path
        forward_missing_to @cursor

        abstract def flush : Nil

        def <=>(other : self) : Int32
        end

        def each(& : String ->) : Nil
        end

        def run : Hit | Miss
        end

        protected abstract def prepare : Nil

        protected getter owner : String

        protected def touch : Nil
        end

        private abstract def locate : Cursor

        private getter secret : Int32

        private def scan : Nil
        end

        private record Pending, path : String

        private struct Scratch
        end
      end
      CRYSTAL
  end

  it "reports a mixin below a constant" do
    expect_issue subject, <<-CRYSTAL
      class Foo
        LIMIT = 1
        include Comparable(Foo)
      # ^^^^^^^^^^^^^^^^^^^^^^^ error: Mixins come before constants, so `include Comparable(Foo)` belongs above `LIMIT`
      end
      CRYSTAL
  end

  it "reports a constant below a nested type" do
    expect_issue subject, <<-CRYSTAL
      class Foo
        record Bar, id : Int32
        LIMIT = 1
      # ^^^^^^^^^ error: Constants come before nested types, so `LIMIT` belongs above `record Bar`
      end
      CRYSTAL
  end

  it "reports a class variable below a class method" do
    expect_issue subject, <<-CRYSTAL
      class Foo
        def self.count : Int32
        end

        @@count = 0
      # ^^^^^^^^^^^ error: Class variables come before public class methods, so `@@count` belongs above `self.count`
      end
      CRYSTAL
  end

  it "reports a private class method below initialize" do
    expect_issue subject, <<-CRYSTAL
      class Foo
        def initialize
        end

        private def self.build : Foo
      # ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ error: Private class methods come before constructors, so `self.build` belongs above `initialize`
        end
      end
      CRYSTAL
  end

  it "reports an instance variable declaration below initialize" do
    expect_issue subject, <<-CRYSTAL
      class Foo
        def initialize
        end

        @count : Int32
      # ^^^^^^^^^^^^^^ error: Instance variable declarations come before constructors, so `@count` belongs above `initialize`
      end
      CRYSTAL
  end

  it "treats an instance variable with an initial value as a declaration" do
    expect_issue subject, <<-CRYSTAL
      class Foo
        def initialize
        end

        @count = 0
      # ^^^^^^^^^^ error: Instance variable declarations come before constructors, so `@count` belongs above `initialize`
      end
      CRYSTAL
  end

  it "reports initialize below accessors" do
    expect_issue subject, <<-CRYSTAL
      class Foo
        getter name : String
        getter? ready : Bool

        def initialize(@name : String)
      # ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ error: Constructors come before accessors, so `initialize` belongs above `getter name`
        end
      end
      CRYSTAL
  end

  it "reports an abstract method below a concrete one of the same visibility" do
    expect_issue subject, <<-CRYSTAL
      abstract class Foo
        def run : Nil
        end

        abstract def step : Nil
      # ^^^^^^^^^^^^^^^^^^^^^^^ error: Public abstract methods come before public instance methods, so `step` belongs above `run`
      end
      CRYSTAL
  end

  it "reports a public method below a protected one" do
    expect_issue subject, <<-CRYSTAL
      class Foo
        protected def touch : Nil
        end

        def run : Nil
      # ^^^^^^^^^^^^^ error: Public instance methods come before protected instance methods, so `run` belongs above `touch`
        end
      end
      CRYSTAL
  end

  it "reports a private nested type above private methods" do
    expect_issue subject, <<-CRYSTAL
      class Foo
        private def scan : Nil
        end

        private record Pending, id : Int32
      # ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ error: Private nested types come after private instance methods, so `record Pending` belongs below `sweep`

        private def sweep : Nil
        end
      end
      CRYSTAL
  end

  it "reports a constant sandwiched between class methods" do
    expect_issue subject, <<-CRYSTAL
      class Foo
        def self.build : Foo
        end

        LIMIT = 1
      # ^^^^^^^^^ error: Constants come before public class methods, so `LIMIT` belongs above `self.build`

        def self.parse(raw : String) : Foo
        end
      end
      CRYSTAL
  end

  it "reports only the member that is out of place" do
    expect_issue subject, <<-CRYSTAL
      class Foo
        def run : Nil
      # ^^^^^^^^^^^^^ error: Public instance methods come after constructors, so `run` belongs below `initialize`
        end

        LIMIT = 1

        def self.build : Foo
        end

        def initialize
        end
      end
      CRYSTAL
  end

  it "reports enum methods above enum members" do
    expect_issue subject, <<-CRYSTAL
      enum Mode
        def label : String
      # ^^^^^^^^^^^^^^^^^^ error: Public instance methods come after enum members, so `label` belongs below `Write`
        end

        Read
        Write
      end
      CRYSTAL
  end

  it "checks nested types on their own" do
    expect_issue subject, <<-CRYSTAL
      class Outer
        class Inner
          def run : Nil
          end

          LIMIT = 1
        # ^^^^^^^^^ error: Constants come before public instance methods, so `LIMIT` belongs above `run`
        end

        def initialize
        end
      end
      CRYSTAL
  end

  it "treats a private initialize as the constructor" do
    expect_no_issues subject, <<-CRYSTAL
      class Foo
        def self.build : Foo
          new
        end

        private def initialize
        end

        private def scan : Nil
        end
      end
      CRYSTAL
  end

  it "corrects accessors above initialize" do
    source = expect_issue subject, <<-CRYSTAL
      class Foo
        getter name : String
        getter? ready : Bool

        def initialize(@name : String)
      # ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ error: Constructors come before accessors, so `initialize` belongs above `getter name`
        end
      end
      CRYSTAL

    expect_correction source, <<-CRYSTAL
      class Foo
        def initialize(@name : String)
        end

        getter name : String
        getter? ready : Bool
      end
      CRYSTAL
  end

  it "corrects a private nested type and keeps its annotation and comment" do
    source = expect_issue subject, <<-CRYSTAL
      class Foo
        # pending writes wait for the next cycle
        @[Deprecated]
        private record Pending, id : Int32
      # ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ error: Private nested types come after private instance methods, so `record Pending` belongs below `scan`

        def initialize
        end

        private def scan : Nil
        end
      end
      CRYSTAL

    expect_correction source, <<-CRYSTAL
      class Foo
        def initialize
        end

        private def scan : Nil
        end

        # pending writes wait for the next cycle
        @[Deprecated]
        private record Pending, id : Int32
      end
      CRYSTAL
  end

  it "groups single-line members of one section when they become neighbours" do
    source = expect_issue subject, <<-CRYSTAL
      class Foo
        getter first : Int32

        def initialize
      # ^^^^^^^^^^^^^^ error: Constructors come before accessors, so `initialize` belongs above `getter first`
        end

        getter second : Int32
      end
      CRYSTAL

    expect_correction source, <<-CRYSTAL
      class Foo
        def initialize
        end

        getter first : Int32
        getter second : Int32
      end
      CRYSTAL
  end

  it "corrects every misplaced member of a body in one rewrite" do
    corrected = correct_until_stable(subject, <<-CRYSTAL)
      class Foo
        private def scan : Nil
        end

        LIMIT = 1

        def run : Nil
        end

        alias Name = String

        private record Pending, id : Int32

        def self.build : Foo
        end

        record Hit, id : Int32

        def initialize
        end

        include Comparable(Foo)
      end
      CRYSTAL

    corrected.should eq(<<-CRYSTAL)
      class Foo
        include Comparable(Foo)

        LIMIT = 1

        alias Name = String

        record Hit, id : Int32

        def self.build : Foo
        end

        def initialize
        end

        def run : Nil
        end

        private def scan : Nil
        end

        private record Pending, id : Int32
      end
      CRYSTAL
  end

  it "corrects a nested type and its owner across passes" do
    corrected = correct_until_stable(subject, <<-CRYSTAL)
      class Outer
        def initialize
        end

        class Inner
          def run : Nil
          end

          LIMIT = 1
        end
      end
      CRYSTAL

    corrected.should eq(<<-CRYSTAL)
      class Outer
        class Inner
          LIMIT = 1

          def run : Nil
          end
        end

        def initialize
        end
      end
      CRYSTAL
  end

  it "leaves a body with unknown macro calls uncorrected" do
    source = expect_issue subject, <<-CRYSTAL
      class Foo
        getter name : String

        some_dsl :thing

        def initialize
      # ^^^^^^^^^^^^^^ error: Constructors come before accessors, so `initialize` belongs above `getter name`
        end
      end
      CRYSTAL

    expect_no_corrections source
  end

  it "places a compile-time block with its contents" do
    source = expect_issue subject, <<-CRYSTAL
      class Foo
        def initialize
        end

        {% if flag?(:darwin) %}
      # ^^^^^^^^^^^^^^^^^^^^^^^ error: Private class methods come before constructors, so `{% if flag?(:darwin) %}` belongs above `initialize`
          private def self.modified_at : Int32
          end
        {% elsif flag?(:linux) %}
          private def self.modified_at : Int32
          end
        {% else %}
          {% raise "unsupported" %}
        {% end %}
      end
      CRYSTAL

    expect_correction source, <<-CRYSTAL
      class Foo
        {% if flag?(:darwin) %}
          private def self.modified_at : Int32
          end
        {% elsif flag?(:linux) %}
          private def self.modified_at : Int32
          end
        {% else %}
          {% raise "unsupported" %}
        {% end %}

        def initialize
        end
      end
      CRYSTAL
  end

  it "places a mixed compile-time block by its earliest section" do
    expect_issue subject, <<-CRYSTAL
      class Foo
        def self.build : Foo
        end

        {% if flag?(:timing) %}
      # ^^^^^^^^^^^^^^^^^^^^^^^ error: Class variables come before public class methods, so `{% if flag?(:timing) %}` belongs above `self.build`
          class_property calls = 0

          def self.reset : Nil
          end
        {% end %}
      end
      CRYSTAL
  end

  it "ignores annotations, unknown macro calls and compile-time blocks it cannot place" do
    expect_no_issues subject, <<-CRYSTAL
      class Foo
        include JSON::Serializable

        {% if flag?(:linux) %}
          require "linux_only"
        {% end %}

        some_dsl :thing

        def initialize
        end

        @[JSON::Field(key: "n")]
        getter name : String
      end
      CRYSTAL
  end
end
