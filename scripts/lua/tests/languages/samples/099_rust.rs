use std::fmt::{self, Display};

#[derive(Debug, Clone)]
pub struct Widget<T> {
    value: T,
}

pub enum State<'a> {
    Ready(&'a str),
    Waiting { retries: usize },
    Failed,
}

pub trait Render {
    type Output;
    fn render(&self) -> Self::Output;
}

impl<T: Display> Widget<T> {
    pub fn new(value: T) -> Self { Self { value } }
    pub async fn render(&self) -> Result<String, fmt::Error> {
        match format!("{}", self.value).as_str() {
            "" => Ok(String::from("empty")),
            text if text.len() > 3 => Ok(text.to_owned()),
            _ => Ok("short".into()),
        }
    }
}

impl<T: Display> Render for Widget<T> {
    type Output = String;
    fn render(&self) -> Self::Output {
        let mut out = String::new();
        loop {
            out.push_str(&format!("{}", self.value));
            break;
        }
        out
    }
}

macro_rules! widget {
    ($value:expr) => {
        Widget::new($value)
    };
}

unsafe extern "C" fn callback(value: i32) -> i32 {
    value + 1
}

None Option Result Self Some String as async await bool break char const continue crate dyn else enum extern f128 f32 f64 false fn for i128 i16 i32 i64 i8 if impl in isize let loop match mod move mut pub ref return self static str struct super trait true type u16 u32 u64 u8 unsafe use usize where while ;
