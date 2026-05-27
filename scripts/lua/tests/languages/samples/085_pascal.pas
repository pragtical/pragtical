program Fixture;

type
  TStatus = (stReady, stDisabled);

  IRenderer = interface
    ['{6D6C7429-77AB-41E0-9D8C-C72823D84325}']
    procedure Render;
  end;

  TWidget = class
  private
    FName: string;
    FStatus: TStatus;
  public
    constructor Create(const AName: string);
    procedure Render;
    property Name: string read FName write FName;
  end;

constructor TWidget.Create(const AName: string);
begin
  FName := AName;
  FStatus := stReady;
end;

procedure TWidget.Render;
var
  I: Integer;
begin
  for I := 0 to 2 do
  begin
    case FStatus of
      stReady: WriteLn(FName, ':', I);
      stDisabled: Break;
    end;
  end;
end;

begin
  with TWidget.Create('demo') do
  try
    Render;
  finally
    Free;
  end;
end.
