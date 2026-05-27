module Main exposing (Model, Msg(..), init, update, view)

import Html exposing (Html, button, div, text)
import Html.Events exposing (onClick)

type alias Model =
    { count : Int, title : String }

type Msg
    = Increment
    | Reset

init : Model
init =
    { count = 0, title = "Demo" }

update : Msg -> Model -> Model
update msg model =
    case msg of
        Increment ->
            { model | count = model.count + 1 }

        Reset ->
            init

view : Model -> Html Msg
view model =
    div [] [ button [ onClick Increment ] [ text model.title ] ]
