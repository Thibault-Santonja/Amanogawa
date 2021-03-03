import React, { useState } from 'react';
import {
    Collapse,
    Navbar,
    NavbarToggler,
    NavbarBrand,
    Nav,
    NavItem,
    NavLink
} from 'reactstrap';

const Header = () => {
    const [isOpen, setIsOpen] = useState(false);

    const toggle = () => setIsOpen(!isOpen);

    return(
        // remove `expand="md"` from <Navbar ...> to allow toggler
        <>
            <Navbar color="dark" dark expand="md">
                <NavbarBrand href="/" className="mr-auto">Amanogawa</NavbarBrand>
                <NavbarToggler onClick={toggle}  className="mr-2" />
                <Collapse isOpen={isOpen} navbar>
                    <Nav navbar>
                        <NavItem>
                            <NavLink href="/events">Events list</NavLink>
                        </NavItem>
                        <NavItem>
                            <NavLink href="/map">Map</NavLink>
                        </NavItem>
                        <NavItem>
                            <NavLink href="/edit">Edit</NavLink>
                        </NavItem>
                    </Nav>
                </Collapse>
            </Navbar>
        </>
    )
};

export {Header};