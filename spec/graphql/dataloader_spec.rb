# frozen_string_literal: true
require "spec_helper"

describe "GraphQL::Dataloader" do
  module DataloaderTest
    module Backend
      LOG = []
      DATA = {
        "b1" => { title: "Remembering", author_id: "a1" },
        "b2" => { title: "That Distant Land", author_id: "a1" },
        "b3" => { title: "Doggies", author_id: "a2" },
        "a1" => { name: "Wendell Berry", book_ids: ["b1", "b2"] },
        "a2" => { name: "Sandra Boynton", book_ids: ["b3"] },
      }

      def self.mget(keys)
        LOG << "MGET #{keys}"
        keys.map { |k| DATA[k] }
      end
    end

    class BackendLoader < GraphQL::Dataloader::Loader
      def self.load_object(ctx, id)
        load(ctx, nil, id)
      end

      def perform(ids)
        Backend.mget(ids)
      end
    end

    class Schema < GraphQL::Schema
      class Author < GraphQL::Schema::Object
        field :name, String, null: false
        field :books, [GraphQL::Schema::LateBoundType.new("Book")], null: false

        def books
          BackendLoader.load_all(context, nil, object[:book_ids])
        end
      end

      class Book < GraphQL::Schema::Object
        field :title, String, null: false
        field :author, Author, null: false

        def author
          BackendLoader.load_object(context, object[:author_id])
        end
      end

      class Query < GraphQL::Schema::Object
        field :book, Book, null: true do
          argument :id, ID, required: true
        end

        def book(id:)
          BackendLoader.load_object(@context, id)
        end

        field :author, Author, null: true do
          argument :id, ID, required: true
        end

        def author(id:)
          BackendLoader.load_object(@context, id)
        end
      end

      query(Query)
      use GraphQL::Execution::Interpreter
      use GraphQL::Analysis::AST
      use GraphQL::Dataloader
    end
  end

  def exec_query(*args)
    DataloaderTest::Schema.execute(*args)
  end

  let(:log) { DataloaderTest::Backend::LOG }

  before do
    log.clear
  end

  it "batches requests" do
    res = exec_query('{
      b1: book(id: "b1") { title author { name } }
      b2: book(id: "b2") { title author { name } }
    }')

    assert_equal "Remembering", res["data"]["b1"]["title"]
    assert_equal "Wendell Berry", res["data"]["b1"]["author"]["name"]
    assert_equal "That Distant Land", res["data"]["b2"]["title"]
    assert_equal "Wendell Berry", res["data"]["b2"]["author"]["name"]
    assert_equal ['MGET ["b1", "b2"]', 'MGET ["a1"]'], log
  end

  it "batches requests across branches of a query" do
    exec_query('{
      a1: author(id: "a1") { books { title } }
      a2: author(id: "a2") { books { title } }
    }')

    expected_log = [
      "MGET [\"a1\", \"a2\"]",
      "MGET [\"b1\", \"b2\", \"b3\"]"
    ]
    assert_equal expected_log, log
  end

  it "doesn't load the same object over again" do
    exec_query('{
      b1: book(id: "b1") {
        title
        author { name }
      }
      a1: author(id: "a1") {
        books {
          author {
            books {
              title
            }
          }
        }
      }
    }')

    expected_log = [
      'MGET ["b1", "a1"]',
      'MGET ["b2"]'
    ]
    assert_equal expected_log, log
  end

  it "shares over a multiplex" do
    query_string = "query($id: ID!) { author(id: $id) { name } }"
    results = DataloaderTest::Schema.multiplex([
      { query: query_string, variables: { "id" => "a1" } },
      { query: query_string, variables: { "id" => "a2" } },
    ])

    assert_equal "Wendell Berry", results[0]["data"]["author"]["name"]
    assert_equal "Sandra Boynton", results[1]["data"]["author"]["name"]
    assert_equal ["MGET [\"a1\", \"a2\"]"], log
  end
end