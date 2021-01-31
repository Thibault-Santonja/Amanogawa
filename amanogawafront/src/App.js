import './App.css';
import Map from './pages/map';
import {Event} from './components/event';


function App() {
  return (
    <div className="App">
      <header className="App-header">
        <h1>Coucou LuLu</h1>
          <Event />
          <Map />
      </header>
    </div>
  );
}

export default App;
