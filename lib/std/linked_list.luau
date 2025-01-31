--!strict
--!native
--!optimize 2

export type Node<T> = {
    value: T,
    next: Node<T>?,
    prev: Node<T>?,
};

type Metatable<T> = {
    __index: Metatable<T>,
    append: (self: LinkedList<T>, node: Node<T>) -> (),
    remove: (self: LinkedList<T>, node: Node<T>) -> (),
    pop: (self: LinkedList<T>) -> Node<T>?,
    popFront: (self: LinkedList<T>) -> Node<T>?,
    iterate: (self: LinkedList<T>) -> ((_: any?, node: Node<T>?) -> (Node<T>, T)),
}

export type LinkedList<T> = typeof(setmetatable({}::{
    head: Node<T>?,
    tail: Node<T>?,
    size: number,
}, {}::Metatable<T>))

local linkedlist = {}
linkedlist.__index = linkedlist

function linkedlist.append(self: LinkedList<any>, node: Node<any>): ()
    if (self.tail) then
        self.tail.next = node
        node.prev = self.tail
        node.next = nil
        self.tail = node
    else
        self.head = node
        self.tail = node
        node.next = nil
        node.prev = nil
    end
    self.size += 1
end

function linkedlist.remove(self: LinkedList<any>, node: Node<any>): ()
    if (node.prev) then
        node.prev.next = node.next
    else
        self.head = node.next
    end
    if (node.next) then
        node.next.prev = node.prev
    else
        self.tail = node.prev
    end
    self.size -= 1
end

function linkedlist.pop(self: LinkedList<any>): Node<any>?
    if (self.tail == nil) then
        return nil
    end
    local node = self.tail
    self:remove(node)
    return node
end

function linkedlist.popFront(self: LinkedList<any>): Node<any>?
    if (self.head == nil) then
        return nil
    end
    local node = self.head
    self:remove(node)
    return node
end

function linkedlist.iterate(self: LinkedList<any>)
    return function(_, node: Node<any>?): (Node<any>, any)
        if (node == nil) then
            if (self.head ~= nil) then
                return self.head, self.head.value
            end
        else
            local next = node.next
            if (next ~= nil) then
                return next, next.value
            end
        end
        return nil::any, nil::any;
    end
end

function linkedlist.new<T>(): LinkedList<T>
    return setmetatable({
        head = nil,
        tail = nil,
        size = 0,
    }, linkedlist)
end

return linkedlist
