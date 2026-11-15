-module(example).
-export([run/0, add/2]).
-define(ANSWER, 16#2A).
-record(state, {count = 0, name = "ready"}).

% Exercise attributes, atoms, macros, records and guarded functions.
add(Left, Right) when is_integer(Left), is_integer(Right) ->
    Left + Right.

run() ->
    State = #state{count = ?ANSWER},
    Atom = 'quoted atom',
    Escaped = "line\n\x{41}",
    Character = $\x{41},
    Raw = ~S"literal\n",
    Sigil = ~s"escaped\n",
    Multiline = """
        first line
        second line
        """,
    Bytes = <<1:8, 2:8>>,
    Squares = [N * N || N <- [1, 2, 3]],
    self() ! {done, State#state.count},
    receive
        {done, Value} ->
            {Value, Atom, Escaped, Character, Raw, Sigil, Multiline, Bytes, Squares}
    after 0 ->
        false
    end.
