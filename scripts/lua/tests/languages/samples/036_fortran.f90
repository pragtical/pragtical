module fixture_mod
  implicit none
  type :: widget
    character(len=32) :: name
  contains
    procedure :: render
  end type widget
contains
  subroutine render(self, count)
    class(widget), intent(in) :: self
    integer, intent(in) :: count
    if (count > 0) print *, trim(self%name), count
  end subroutine render
end module fixture_mod
