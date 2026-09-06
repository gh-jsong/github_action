package com.song.action;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("hello")
public class HelloAction {

    @GetMapping("{name}")
    public String hello(@PathVariable("name") String name) {
        return "hello : " + name;
    }
}
