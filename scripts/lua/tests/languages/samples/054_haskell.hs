module Demo where

data Widget a = Widget { name :: String, value :: a }
  deriving (Show, Eq)

render :: Show a => Widget a -> [String] -> String
render widget items =
  case items of
    [] -> name widget
    xs -> foldr (++) "" xs

as case class data default deriving do else forall foreign hiding if import in infix infixl infixr let mdo module newtype of qualified then type where ;
