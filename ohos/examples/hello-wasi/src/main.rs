use std::env;
use std::fs;
use std::io::{self, Read};
use std::thread;
use std::time::Duration;

fn main() {
    let args: Vec<String> = env::args().collect();
    println!("Hello from WASI on HarmonyOS!");
    println!("args: {args:?}");
    if let Ok(value) = env::var("GREETING") {
        println!("GREETING={value}");
    }
    if let Some(position) = args.iter().position(|arg| arg == "--exit") {
        if let Some(code) = args.get(position + 1).and_then(|code| code.parse().ok()) {
            eprintln!("exiting with {code}");
            std::process::exit(code);
        }
    }
    if let Some(position) = args.iter().position(|arg| arg == "--sleep") {
        if let Some(milliseconds) = args.get(position + 1).and_then(|value| value.parse().ok()) {
            thread::sleep(Duration::from_millis(milliseconds));
        }
    }
    let mut input = String::new();
    if io::stdin().read_to_string(&mut input).is_ok() && !input.is_empty() {
        println!("stdin: {}", input.trim_end());
    }
    let path = "/tmp/wasmer-demo.txt";
    if fs::write(path, "written by WASI\n").is_ok() {
        if let Ok(contents) = fs::read_to_string(path) {
            print!("file: {contents}");
        }
    }
    println!("done.");
}
