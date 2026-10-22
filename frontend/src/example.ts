// FE-02: struct, trait, iterator 를 보여주는 예제. 실행하면 의미 있는 출력이 나온다.
export const EXAMPLE_CODE = `trait Shape {
    fn name(&self) -> String;
    fn area(&self) -> f64;
}

struct Circle {
    radius: f64,
}

struct Rect {
    w: f64,
    h: f64,
}

impl Shape for Circle {
    fn name(&self) -> String {
        format!("Circle(r={})", self.radius)
    }
    fn area(&self) -> f64 {
        std::f64::consts::PI * self.radius * self.radius
    }
}

impl Shape for Rect {
    fn name(&self) -> String {
        format!("Rect({}x{})", self.w, self.h)
    }
    fn area(&self) -> f64 {
        self.w * self.h
    }
}

fn main() {
    let shapes: Vec<Box<dyn Shape>> = vec![
        Box::new(Circle { radius: 1.5 }),
        Box::new(Rect { w: 3.0, h: 4.0 }),
        Box::new(Circle { radius: 0.5 }),
    ];

    for s in &shapes {
        println!("{:<14} area = {:.2}", s.name(), s.area());
    }

    let total: f64 = shapes.iter().map(|s| s.area()).sum();
    println!("total area = {:.2}", total);

    let squares: Vec<u32> = (1..=10).filter(|n| n % 2 == 0).map(|n| n * n).collect();
    println!("even squares = {:?}", squares);
}
`
