import './App.css';
import {BrowserRouter, Route, Switch} from "react-router-dom";
import {Events} from './pages/events';
import {Index} from "./pages/index"
import Map from './pages/map';
import {Header} from "./components/header";


function App() {
  return (
    <div className="App">
        <Header />
        <BrowserRouter>
            <Switch>
                <Route exact path="/" component={Index}/>
                <Route exact path="/map" component={Map}/>
                <Route exact path="/events" component={Events}/>
            </Switch>
        </BrowserRouter>
    </div>
  );
}

export default App;
