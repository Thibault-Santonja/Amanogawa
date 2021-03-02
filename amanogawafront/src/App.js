import './App.css';
import {BrowserRouter, Route, Switch} from "react-router-dom";
import {useEffect} from 'react';
import {Events} from './pages/events';
import {Index} from "./pages/index";
import {Edit} from "./pages/edit";
import Map from './pages/map';
import {Header} from "./components/header";


function App() {
    useEffect(() => {
        document.title = "Amanogawa"
    }, []);

    return (
    <div className="App">
        <Header />
        <BrowserRouter>
            <Switch>
                <Route exact path="/" component={Index}/>
                <Route exact path="/map" component={Map}/>
                <Route exact path="/events" component={Events}/>
                <Route exact path="/edit" component={Edit}/>
            </Switch>
        </BrowserRouter>
    </div>
    );
}

export default App;
