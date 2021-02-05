import React, {Component} from 'react';
import 'bootstrap/dist/css/bootstrap.min.css';
import TimelineSlider from '../components/timelineRange'

// Resources
import logo from '../assets/YoDance.gif';


const startTime = 0; //-4000; aie aie aie pas de dates négatives.............
const endTime   = new Date().getFullYear();

class Index extends Component {
    render() {
        return(
            <>
                <h1>Welcome !</h1>
                <br />
                <img src={logo} alt="loading..." />
                <br />
                <br />
                <h2>TODO</h2>

                <div className="d-flex justify-content-center fixed-bottom">
                    <div className="w-75">
                        <h2>Test timeline :</h2>
                        <p>Timeline Range Slider : {startTime} to {endTime}</p>
                        <TimelineSlider startTime={startTime} endTime={endTime}/>
                    </div>
                </div>
            </>
        )
    };
}

export {Index};