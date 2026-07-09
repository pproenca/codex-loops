%{
  configs: [
    %{
      name: "default",
      checks: %{
        disabled: [
          # The workflow compiler, predicate evaluator, and run writer contain
          # deliberately dense DSL/runtime folds. Keep Credo focused on concrete
          # warnings and readability until those areas are intentionally split.
          {Credo.Check.Refactor.CyclomaticComplexity, false},
          {Credo.Check.Refactor.FunctionArity, false},
          {Credo.Check.Refactor.Nesting, false},

          # The predicate evaluator intentionally relies on BEAM float semantics
          # while keeping the helper name as documentation of JSON intent.
          {Credo.Check.Warning.OperationOnSameValues, false}
        ]
      }
    }
  ]
}
