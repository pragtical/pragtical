FUNCTION_BLOCK FB_Widget
VAR_INPUT
  Enable : BOOL;
  Count : INT;
END_VAR
VAR_OUTPUT
  Done : BOOL;
END_VAR
VAR
  Index : INT := 0;
  Name : STRING := 'demo';
  State : (Idle, Running, Faulted);
END_VAR

CASE State OF
  Idle:
    IF Enable THEN
      State := Running;
    END_IF;
  Running:
    FOR Index := 0 TO Count BY 1 DO
      Done := Index > 10 AND NOT FALSE;
    END_FOR;
  Faulted:
    WHILE Enable DO
      EXIT;
    END_WHILE;
END_CASE;
